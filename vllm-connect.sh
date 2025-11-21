#!/usr/bin/env bash

# Alvis vLLM Connection Automation Script
# Automates job submission, monitoring, and SSH tunnel establishment

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_JSON="${SCRIPT_DIR}/models.json"
JOBSCRIPT_TEMPLATE="${SCRIPT_DIR}/jobscript.sh"
SESSION_FILE="$HOME/.vllm-session"
LOCAL_PORT=58000
SSH_HOST="alvis2"
SSH_USER="pradas"
SSH_JUMP_HOST="${SSH_USER}@alvis2.c3se.chalmers.se"

# Timeouts (in seconds)
JOB_START_TIMEOUT=600
SERVER_READY_TIMEOUT=600
CONNECTION_TEST_TIMEOUT=30

# Global variables for cleanup
JOB_ID=""
SSH_TUNNEL_PID=""
LOG_STREAM_PID=""
NODE_NAME=""
SERVER_INFO=""
MODEL_CATALOG=""
MODEL_NUMBER_MAP_FILE=""
CLEANUP_DONE=false

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

timestamp() {
    date +"%H:%M:%S"
}

info() {
    echo -e "${BLUE}[$(timestamp)]${NC} ${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${BLUE}[$(timestamp)]${NC} ${BLUE}[INFO]${NC} ${GREEN}✓${NC} $*"
}

error() {
    echo -e "${BLUE}[$(timestamp)]${NC} ${RED}[ERROR]${NC} $*" >&2
}

warning() {
    echo -e "${BLUE}[$(timestamp)]${NC} ${YELLOW}[WARN]${NC} $*"
}

# Cleanup function - called on exit
cleanup() {
    # Prevent cleanup from running multiple times
    if [[ "${CLEANUP_DONE}" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    local exit_code=$?

    echo ""
    info "Cleaning up..."

    # Kill log streaming process
    if [[ -n "${LOG_STREAM_PID}" ]]; then
        kill "${LOG_STREAM_PID}" 2>/dev/null || true
    fi

    # Close SSH tunnel
    if [[ -n "${SSH_TUNNEL_PID}" ]]; then
        kill "${SSH_TUNNEL_PID}" 2>/dev/null || true
        info "Closed SSH tunnel"
    fi

    # Cancel SLURM job
    if [[ -n "${JOB_ID}" ]]; then
        info "Cancelling job ${JOB_ID}..."
        ssh "${SSH_HOST}" "scancel ${JOB_ID}" 2>/dev/null || true
        success "Cleaned up job ${JOB_ID}"
    fi

    # Clean up model catalog temp file
    if [[ -n "${MODEL_CATALOG}" && -f "${MODEL_CATALOG}" ]]; then
        rm -f "${MODEL_CATALOG}" 2>/dev/null || true
    fi

    # Clean up model number mapping temp file
    if [[ -n "${MODEL_NUMBER_MAP_FILE}" && -f "${MODEL_NUMBER_MAP_FILE}" ]]; then
        rm -f "${MODEL_NUMBER_MAP_FILE}" 2>/dev/null || true
    fi

    exit "${exit_code}"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Spinner function for progress indication
spinner() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${BLUE}[INFO]${NC} %s %s" "$message" "${spin:$i:1}"
        sleep 0.2
    done
    printf "\r"
}

# Timeout function for macOS compatibility
# Usage: run_with_timeout <seconds> <command> [args...]
run_with_timeout() {
    local timeout=$1
    shift

    # Run command in background
    "$@" &
    local pid=$!

    # Wait for timeout or command completion
    local count=0
    while kill -0 $pid 2>/dev/null && [ $count -lt $timeout ]; do
        sleep 1
        count=$((count + 1))
    done

    # Kill if still running
    if kill -0 $pid 2>/dev/null; then
        kill -9 $pid 2>/dev/null
        wait $pid 2>/dev/null
        return 124  # timeout exit code
    fi

    wait $pid
    return $?
}

# Show help message
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automate vLLM server connection on Alvis cluster.

OPTIONS:
  -m, --model MODEL_NAME    Model to use (default: gpt-oss-20b)
  -i, --interactive         Interactive model selection menu
  -t, --time DURATION       Job duration in HH:MM:SS format (default: 1:00:00)
  -h, --help               Show this help message
  --list-models            List available models (auto-discovered + configured)

EXAMPLES:
  $(basename "$0")                          # Use defaults
  $(basename "$0") -i                       # Interactive model selection
  $(basename "$0") -m gpt-oss-20b -t 2:00:00  # Custom model and time
  $(basename "$0") --list-models            # Show available models

NOTE:
  Models are auto-discovered from /mimer/NOBACKUP/Datasets/LLM/huggingface/hub/
  Use models.json to override defaults (max_model_len, descriptions)

EOF
}

# Format models in grouped, compact display
# Returns: formatted output and stores mapping in temp file
format_models_grouped() {
    local catalog=$1

    # Create temp file for number-to-model mapping
    MODEL_NUMBER_MAP_FILE=$(mktemp)

    # Get all models sorted by org, then by name
    local models_json=$(jq -r '
        to_entries
        | map(select(.key | startswith("_") | not))
        | sort_by(.key)
        | .[]
        | "\(.key)|\(.value.max_model_len)"
    ' "$catalog")

    local counter=1
    local current_org=""

    while IFS='|' read -r full_model max_len; do
        [[ -z "$full_model" ]] && continue

        local org=$(echo "$full_model" | cut -d'/' -f1)
        local name=$(echo "$full_model" | cut -d'/' -f2-)

        # Print org header when it changes
        if [[ "$org" != "$current_org" ]]; then
            echo ""
            echo -e "${GREEN}${org}:${NC}"
            current_org="$org"
        fi

        # Print model entry
        printf "  %2d. %-50s ${BLUE}(max: %s)${NC}\n" "$counter" "$name" "$max_len"

        # Store mapping in temp file
        echo "${counter}|${full_model}" >> "$MODEL_NUMBER_MAP_FILE"

        ((counter++))
    done <<< "$models_json"

    echo ""
}

# Get model name by number from mapping file
get_model_by_number() {
    local number=$1
    grep "^${number}|" "$MODEL_NUMBER_MAP_FILE" | cut -d'|' -f2
}

# List available models
list_models() {
    local catalog=$1

    info "Available models:"

    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed"
        exit 1
    fi

    format_models_grouped "$catalog"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

preflight_checks() {
    local model_name=$1
    local catalog=$2

    info "Running pre-flight checks..."

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed. Install with: brew install jq"
        exit 1
    fi

    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        error "curl is required but not installed"
        exit 1
    fi

    # Check if required files exist
    if [[ ! -f "${JOBSCRIPT_TEMPLATE}" ]]; then
        error "jobscript.sh not found at: ${JOBSCRIPT_TEMPLATE}"
        exit 1
    fi

    # Validate catalog
    if ! jq empty "$catalog" 2>/dev/null; then
        error "Model catalog contains invalid JSON"
        exit 1
    fi

    # Check if model exists in catalog
    if ! jq -e --arg model "$model_name" '.[$model]' "$catalog" &>/dev/null; then
        error "Model '${model_name}' not found in catalog"
        echo ""
        list_models "$catalog"
        exit 1
    fi

    # Check if local port is available
    if lsof -Pi :${LOCAL_PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
        error "Port ${LOCAL_PORT} is already in use"
        info "Kill the process using: kill \$(lsof -ti:${LOCAL_PORT})"
        exit 1
    fi

    # Check SSH connection
    info "Checking SSH connection to ${SSH_HOST}..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${SSH_HOST}" "echo 'SSH connection successful'" &>/dev/null; then
        error "Cannot connect to ${SSH_HOST}"
        error "Ensure SSH key authentication is configured"
        exit 1
    fi
    success "SSH connection successful"
}

# ============================================================================
# Model Configuration
# ============================================================================

# Discover available models from Alvis HuggingFace cache
discover_models_from_alvis() {
    local hub_path="/mimer/NOBACKUP/Datasets/LLM/huggingface/hub"

    # SSH to Alvis and discover models
    local discovery_script='
        hub_path="$1"

        # Find all model directories (models--org--name format)
        find "$hub_path" -maxdepth 1 -type d -name "models--*--*" 2>/dev/null | while read -r model_dir; do
            model_base=$(basename "$model_dir")

            # Parse model name: models--org--name → org/name
            org_name=$(echo "$model_base" | sed "s/^models--//; s/--/\//")

            # Find latest snapshot by modification time
            latest_snapshot=$(find "$model_dir/snapshots" -maxdepth 1 -type d 2>/dev/null | \
                grep -v "^$model_dir/snapshots$" | \
                xargs -I {} stat -c "%Y {}" {} 2>/dev/null | \
                sort -rn | head -1 | cut -d" " -f2-)

            if [[ -n "$latest_snapshot" ]]; then
                # Get snapshot hash from path
                snapshot_hash=$(basename "$latest_snapshot")

                # Calculate approximate model size for default max_model_len
                model_size=$(du -sb "$latest_snapshot" 2>/dev/null | cut -f1)

                # Output: model_name|full_path|snapshot_hash|size_bytes
                echo "${org_name}|${latest_snapshot}|${snapshot_hash}|${model_size}"
            fi
        done
    '

    # Execute discovery on Alvis
    ssh -o ConnectTimeout=30 "${SSH_HOST}" "bash -s" "$hub_path" <<< "$discovery_script" 2>/dev/null
}

# Get intelligent default max_model_len based on model name/size
get_default_max_model_len() {
    local model_name=$1
    local model_size=$2

    # Extract number from model name (e.g., "7b", "13b", "70b")
    if [[ "$model_name" =~ ([0-9]+)b ]]; then
        local param_count="${BASH_REMATCH[1]}"

        # Default context lengths based on parameter count
        case "$param_count" in
            [1-7])   echo "4096" ;;
            [8-13])  echo "8192" ;;
            [14-20]) echo "10000" ;;
            [21-34]) echo "16384" ;;
            *)       echo "32768" ;;
        esac
    else
        # Default fallback
        echo "8192"
    fi
}

# Build merged model catalog (discovered + configured)
build_model_catalog() {
    local temp_catalog=$(mktemp)

    # Start with empty catalog
    echo "{}" > "$temp_catalog"

    # Discover models from Alvis
    info "Discovering models from Alvis..." >&2
    local discovered=$(discover_models_from_alvis)

    if [[ -z "$discovered" ]]; then
        warning "No models discovered from Alvis, using models.json only" >&2
        cat "${MODELS_JSON}" > "$temp_catalog"
        echo "$temp_catalog"
        return 0
    fi

    # Process discovered models
    while IFS='|' read -r model_name model_path snapshot_hash model_size; do
        [[ -z "$model_name" ]] && continue

        # Generate default max_model_len
        local default_max_len=$(get_default_max_model_len "$model_name" "$model_size")

        # Check if model exists in models.json (for overrides)
        local override_path=$(jq -r --arg model "$model_name" '.[$model].path // empty' "${MODELS_JSON}" 2>/dev/null)
        local override_max_len=$(jq -r --arg model "$model_name" '.[$model].max_model_len // empty' "${MODELS_JSON}" 2>/dev/null)
        local override_desc=$(jq -r --arg model "$model_name" '.[$model].description // empty' "${MODELS_JSON}" 2>/dev/null)

        # Use override values if they exist, otherwise use discovered values
        local final_path="${override_path:-$model_path}"
        local final_max_len="${override_max_len:-$default_max_len}"
        local final_desc="${override_desc:-Auto-discovered from Alvis (snapshot: ${snapshot_hash:0:8})}"

        # Add to catalog
        jq --arg model "$model_name" \
           --arg path "$final_path" \
           --arg max_len "$final_max_len" \
           --arg desc "$final_desc" \
           '.[$model] = {path: $path, max_model_len: ($max_len | tonumber), description: $desc}' \
           "$temp_catalog" > "${temp_catalog}.tmp" && mv "${temp_catalog}.tmp" "$temp_catalog"
    done <<< "$discovered"

    # Add any models.json entries that weren't discovered (manual additions)
    if [[ -f "${MODELS_JSON}" ]]; then
        jq -s '.[0] * .[1]' "$temp_catalog" "${MODELS_JSON}" > "${temp_catalog}.tmp" && \
            mv "${temp_catalog}.tmp" "$temp_catalog"
    fi

    echo "$temp_catalog"
}

get_model_config() {
    local model_name=$1
    local field=$2
    local catalog=$3

    jq -r --arg model "$model_name" --arg field "$field" '.[$model][$field]' "$catalog"
}

# Interactive model selection
select_model_interactive() {
    local catalog=$1

    echo ""
    info "Available models:"

    # Display models using grouped format
    format_models_grouped "$catalog"

    # Get total number of models from mapping file
    local total_models=$(wc -l < "$MODEL_NUMBER_MAP_FILE" | tr -d ' ')

    if [[ $total_models -eq 0 ]]; then
        error "No models available"
        return 1
    fi

    # Prompt for selection
    local selection
    while true; do
        read -p "Select model (1-${total_models}): " selection

        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$total_models" ]]; then
            local selected_model=$(get_model_by_number "$selection")
            echo "$selected_model"
            return 0
        else
            error "Invalid selection. Please enter a number between 1 and ${total_models}"
        fi
    done
}

# ============================================================================
# Job Submission
# ============================================================================

submit_job() {
    local model_name=$1
    local job_duration=$2
    local catalog=$3

    info "Loading model configuration for: ${model_name}"

    local model_path=$(get_model_config "$model_name" "path" "$catalog")
    local max_model_len=$(get_model_config "$model_name" "max_model_len" "$catalog")

    info "Model path: ${model_path}"
    info "Max model length: ${max_model_len}"

    # Create temporary jobscript with substitutions
    local temp_jobscript=$(mktemp)
    sed -e "s|{{TIME}}|${job_duration}|g" \
        -e "s|{{MODEL_PATH}}|${model_path}|g" \
        -e "s|{{MAX_MODEL_LEN}}|${max_model_len}|g" \
        "${JOBSCRIPT_TEMPLATE}" > "${temp_jobscript}"

    # Submit job
    info "Submitting job (duration: ${job_duration})..."

    local submit_output
    if ! submit_output=$(ssh -o ConnectTimeout=30 "${SSH_HOST}" "cat > /tmp/jobscript_$$.sh && sbatch /tmp/jobscript_$$.sh && rm /tmp/jobscript_$$.sh" < "${temp_jobscript}" 2>&1); then
        error "Failed to submit job"
        error "${submit_output}"
        rm "${temp_jobscript}"
        exit 1
    fi

    rm "${temp_jobscript}"

    # Extract job ID from output (format: "Submitted batch job 5382685")
    JOB_ID=$(echo "${submit_output}" | grep -oE '[0-9]+' | head -1)

    if [[ -z "${JOB_ID}" ]]; then
        error "Could not parse job ID from sbatch output: ${submit_output}"
        exit 1
    fi

    info "Job submitted: ${JOB_ID}"
}

# ============================================================================
# Job Monitoring
# ============================================================================

wait_for_job_start() {
    echo ""
    info "Waiting for job to start..."

    local elapsed=0
    local node_name=""
    local last_state=""

    while [[ $elapsed -lt $JOB_START_TIMEOUT ]]; do
        # Check job status with timeout (force kill after 15 seconds)
        local job_info
        job_info=$(run_with_timeout 15 ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "${SSH_HOST}" "squeue -j ${JOB_ID} -h -o '%T %N'" 2>/dev/null || echo "")

        if [[ -z "$job_info" ]]; then
            warning "Could not get job status (timeout or connection issue), retrying..."
            sleep 2
            elapsed=$((elapsed + 2))
            continue
        fi

        local job_state=$(echo "$job_info" | awk '{print $1}')
        node_name=$(echo "$job_info" | awk '{print $2}')

        # Get queue info if in PENDING state
        local queue_info=""
        if [[ "$job_state" == "PENDING" ]]; then
            # Get position among pending jobs (sorted by priority)
            local queue_data=$(run_with_timeout 10 ssh -o ConnectTimeout=5 "${SSH_HOST}" \
                "squeue -p alvis -t PENDING -h -o '%i %Q' | sort -k2 -rn | awk '{print \$1}' | grep -n '^${JOB_ID}\$' | cut -d: -f1" 2>/dev/null || echo "")
            local pending_count=$(run_with_timeout 10 ssh -o ConnectTimeout=5 "${SSH_HOST}" \
                "squeue -p alvis -t PENDING -h | wc -l" 2>/dev/null | tr -d ' ' || echo "")

            if [[ -n "$queue_data" && -n "$pending_count" ]]; then
                queue_info=" (position ${queue_data}/${pending_count})"
            elif [[ -n "$pending_count" && "$pending_count" -gt 0 ]]; then
                queue_info=" (${pending_count} pending)"
            fi
        fi

        # Show state changes
        if [[ "$job_state" != "$last_state" && -n "$last_state" ]]; then
            echo ""
            info "Job state changed: ${last_state} → ${job_state}"
        fi
        last_state="$job_state"

        if [[ "$job_state" == "RUNNING" ]]; then
            echo ""
            success "Job is running on node: ${node_name}"
            info "Monitor job at: https://job.c3se.chalmers.se/alvis/${JOB_ID}"
            NODE_NAME="$node_name"
            return 0
        fi

        local ts=$(timestamp)
        printf "\r${BLUE}[${ts}]${NC} ${BLUE}[INFO]${NC} Waiting for job to start (state: ${job_state}${queue_info})... (${elapsed}s/${JOB_START_TIMEOUT}s)    " >&2
        # Force flush to stderr
        >&2
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    error "Job did not start within ${JOB_START_TIMEOUT} seconds"
    exit 1
}

# ============================================================================
# vLLM Log Streaming (Early Start)
# ============================================================================

start_vllm_streaming() {
    local node_name=$1

    info "Starting vLLM output streaming..."

    # Get the submit directory to find SLURM output file
    local submitdir
    submitdir=$(run_with_timeout 15 ssh -o ConnectTimeout=10 "${SSH_HOST}" "squeue -j ${JOB_ID} -h -o '%Z'" 2>/dev/null || echo "")

    if [[ -z "$submitdir" ]]; then
        warning "Could not determine submit directory"
        return 1
    fi

    local slurm_out="${submitdir}/slurm-${JOB_ID}.out"

    info "Streaming from: ${slurm_out}"
    info "Waiting for vLLM output to start..."
    echo ""
    echo "────────────────────────────────────────────────────────────────"
    info "vLLM output will appear below with timestamps"
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    # Stream from SLURM output file via SSH to LOGIN node
    # Filter lines after the vLLM output marker and add timestamps
    (
        ssh "${SSH_HOST}" bash -s "${slurm_out}" <<'REMOTE_SCRIPT'
            slurm_out="$1"

            # Define colors in the remote script
            BLUE='\033[0;34m'
            NC='\033[0m'

            # Function to get timestamp
            get_timestamp() {
                date +"%H:%M:%S"
            }

            # Wait for the SLURM output file to be created (up to 30 seconds)
            for i in {1..30}; do
                if [[ -f "$slurm_out" ]]; then
                    break
                fi
                sleep 1
            done

            if [[ ! -f "$slurm_out" ]]; then
                echo "Warning: SLURM output file not found after waiting"
                exit 1
            fi

            # Wait for vLLM output to start
            for i in {1..30}; do
                if grep -q "=== vLLM OUTPUT START ===" "$slurm_out" 2>/dev/null; then
                    break
                fi
                sleep 1
            done

            # Stream the SLURM output, showing only lines after the vLLM marker
            # Use tail -F to follow the file
            tail -F "$slurm_out" 2>/dev/null | while IFS= read -r line; do
                # Once we see the marker, start showing output with [vLLM] prefix
                if [[ "$line" == *"=== vLLM OUTPUT START ==="* ]]; then
                    started=1
                    continue
                fi

                # Show lines after the marker with timestamp
                if [[ -n "$started" ]]; then
                    timestamp=$(get_timestamp)
                    printf "[%s] ${BLUE}[vLLM]${NC} %s\n" "$timestamp" "$line"
                fi
            done
REMOTE_SCRIPT
    ) &

    LOG_STREAM_PID=$!
    success "vLLM output streaming started (PID: ${LOG_STREAM_PID})"
    echo ""

    return 0
}

# ============================================================================
# Server Ready Detection
# ============================================================================

wait_for_server_address() {
    local node_name=$1

    info "Waiting for server address..."

    local elapsed=0
    local server_address=""

    # Get the SLURM output file location
    local workdir
    workdir=$(run_with_timeout 15 ssh -o ConnectTimeout=10 "${SSH_HOST}" "squeue -j ${JOB_ID} -h -o '%Z'" 2>/dev/null || echo "")

    if [[ -z "$workdir" ]]; then
        error "Could not determine work directory for job ${JOB_ID}"
        exit 1
    fi

    local slurm_out="${workdir}/slurm-${JOB_ID}.out"

    while [[ $elapsed -lt $SERVER_READY_TIMEOUT ]]; do
        # Parse server address from SLURM output file
        server_address=$(run_with_timeout 15 ssh -o ConnectTimeout=10 "${SSH_HOST}" "grep -oP 'Server will run at \K[^[:space:]]+' ${slurm_out} 2>/dev/null" || echo "")

        if [[ -n "$server_address" ]]; then
            echo ""
            success "Detected vLLM server address: ${server_address}"
            SERVER_INFO="${server_address}|${workdir}"
            return 0
        fi

        local ts=$(timestamp)
        echo -ne "\r${BLUE}[${ts}]${NC} ${BLUE}[INFO]${NC} Waiting for server address... (${elapsed}s/${SERVER_READY_TIMEOUT}s)    "
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    error "Server address not available within ${SERVER_READY_TIMEOUT} seconds"

    # Try to show error logs from SLURM output
    info "Checking SLURM output file..."
    ssh "${SSH_HOST}" "cat ${slurm_out} 2>/dev/null" || echo "Could not read SLURM output"

    exit 1
}

# ============================================================================
# SSH Tunnel
# ============================================================================

establish_tunnel() {
    local server_address=$1
    local node_name=$(echo "$server_address" | cut -d: -f1)
    local remote_port=$(echo "$server_address" | cut -d: -f2)

    info "Establishing SSH tunnel (local port ${LOCAL_PORT})..."
    info "Tunnel: localhost:${LOCAL_PORT} -> ${node_name}:${remote_port} via ${SSH_JUMP_HOST}"

    # Test SSH connection first
    info "Testing SSH connection to ${node_name}..."
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -J "${SSH_JUMP_HOST}" "${SSH_USER}@${node_name}" "echo 'Connection test successful'" >/dev/null 2>&1; then
        error "Cannot establish SSH connection to ${node_name}"
        error "Make sure the job is still running on this node"
        exit 1
    fi

    # Establish tunnel in background (let shell background it, not SSH -f)
    ssh -N -L "${LOCAL_PORT}:localhost:${remote_port}" \
        -o StrictHostKeyChecking=no \
        -o ExitOnForwardFailure=yes \
        -J "${SSH_JUMP_HOST}" \
        "${SSH_USER}@${node_name}" 2>/dev/null &

    SSH_TUNNEL_PID=$!

    # Wait a moment for tunnel to establish
    sleep 2

    # Check if tunnel process is still running
    if ! kill -0 "${SSH_TUNNEL_PID}" 2>/dev/null; then
        error "SSH tunnel failed to establish"
        exit 1
    fi

    success "SSH tunnel established successfully (PID: ${SSH_TUNNEL_PID})"

    # Test connection
    info "Waiting for vLLM model to load and API to become available..."
    info "(This typically takes 2-5 minutes for large models)"

    local retries=0
    local max_retries=150  # 150 retries × 2s = 5 minutes

    while [[ $retries -lt $max_retries ]]; do
        if curl -s --max-time "${CONNECTION_TEST_TIMEOUT}" "http://localhost:${LOCAL_PORT}/v1/models" >/dev/null 2>&1; then
            echo ""
            echo ""
            echo "════════════════════════════════════════════════════════════════"
            success "✓ vLLM server is ready and accepting connections!"
            echo "════════════════════════════════════════════════════════════════"
            echo ""
            info "API endpoint: http://localhost:${LOCAL_PORT}"
            echo ""
            info "Available endpoints:"
            info "  • Models:      http://localhost:${LOCAL_PORT}/v1/models"
            info "  • Completions: http://localhost:${LOCAL_PORT}/v1/completions"
            info "  • Chat:        http://localhost:${LOCAL_PORT}/v1/chat/completions"
            echo ""
            echo "════════════════════════════════════════════════════════════════"
            info "vLLM output will continue streaming below"
            info "Press Ctrl+C to stop and cleanup"
            echo "════════════════════════════════════════════════════════════════"
            echo ""
            return 0
        fi

        # Show progress every 5th attempt (every 10 seconds) to reduce noise
        if (( retries % 5 == 0 )); then
            local ts=$(timestamp)
            local elapsed=$((retries * 2))
            echo -ne "\r${BLUE}[${ts}]${NC} ${BLUE}[INFO]${NC} Waiting for vLLM API to respond... (${elapsed}s elapsed)    "
        fi
        retries=$((retries + 1))
        sleep 2
    done

    echo ""
    error "Connection test failed after ${max_retries} attempts"
    exit 1
}


# ============================================================================
# Session Persistence
# ============================================================================

save_session() {
    local model_name=$1
    local node_name=$2
    local remote_port=$3
    local tmpdir=$4

    cat > "${SESSION_FILE}" << EOF
JOB_ID=${JOB_ID}
NODE=${node_name}
PORT=${remote_port}
LOCAL_PORT=${LOCAL_PORT}
TMPDIR=${tmpdir}
MODEL=${model_name}
STARTED=$(date -u +"%Y-%m-%dT%H:%M:%S")
EOF

    # TODO: Implement session recovery feature to reconnect to existing jobs
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Default values
    local model_name="gpt-oss-20b"
    local job_duration="1:00:00"
    local interactive_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--model)
                model_name="$2"
                shift 2
                ;;
            -i|--interactive)
                interactive_mode=true
                shift
                ;;
            -t|--time)
                job_duration="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --list-models)
                # Build catalog first for listing
                local temp_catalog=$(build_model_catalog)
                list_models "$temp_catalog"
                rm -f "$temp_catalog"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    echo ""
    info "Alvis vLLM Connection Automation"
    info "================================"
    echo ""

    # Build model catalog (auto-discover + configured)
    MODEL_CATALOG=$(build_model_catalog)
    success "Model catalog built successfully"
    echo ""

    # Handle interactive model selection
    if [[ "$interactive_mode" == "true" ]]; then
        model_name=$(select_model_interactive "$MODEL_CATALOG")
        if [[ -z "$model_name" ]]; then
            error "Model selection cancelled"
            exit 1
        fi
        info "Selected model: ${model_name}"
        echo ""
    fi

    # Run pre-flight checks
    preflight_checks "$model_name" "$MODEL_CATALOG"

    # Submit job
    submit_job "$model_name" "$job_duration" "$MODEL_CATALOG"

    # Wait for job to start
    wait_for_job_start
    echo ""

    # Start streaming vLLM output immediately
    start_vllm_streaming "$NODE_NAME"

    # Wait for server to be ready (while streaming continues in background)
    wait_for_server_address "$NODE_NAME"
    local server_address=$(echo "$SERVER_INFO" | cut -d'|' -f1)
    local tmpdir=$(echo "$SERVER_INFO" | cut -d'|' -f2)
    echo ""

    # Parse server address
    local remote_port=$(echo "$server_address" | cut -d: -f2)

    # Establish SSH tunnel (while streaming continues in background)
    establish_tunnel "$server_address"
    echo ""

    # Save session information
    save_session "$model_name" "$NODE_NAME" "$remote_port" "$tmpdir"

    # Keep streaming until user cancels (Ctrl+C)
    if [[ -n "${LOG_STREAM_PID}" ]] && kill -0 "${LOG_STREAM_PID}" 2>/dev/null; then
        wait "${LOG_STREAM_PID}"
    else
        warning "Log streaming process not running"
        info "You can still use the API at http://localhost:${LOCAL_PORT}"
        info "Press Ctrl+C to cleanup and exit"
        # Keep the script running until user cancels
        while true; do
            sleep 1
        done
    fi
}

# Run main function
main "$@"
