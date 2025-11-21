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
  -t, --time DURATION       Job duration in HH:MM:SS format (default: 1:00:00)
  -h, --help               Show this help message
  --list-models            List available models from models.json

EXAMPLES:
  $(basename "$0")                          # Use defaults
  $(basename "$0") -m gpt-oss-20b -t 2:00:00  # Custom model and time
  $(basename "$0") --list-models            # Show available models

EOF
}

# List available models
list_models() {
    info "Available models:"
    echo ""

    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed"
        exit 1
    fi

    jq -r 'to_entries[] | "  \u001b[32m\(.key)\u001b[0m\n    Path: \(.value.path)\n    Max Length: \(.value.max_model_len)\n    Description: \(.value.description // "N/A")\n"' "$MODELS_JSON"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

preflight_checks() {
    local model_name=$1

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
    if [[ ! -f "${MODELS_JSON}" ]]; then
        error "models.json not found at: ${MODELS_JSON}"
        exit 1
    fi

    if [[ ! -f "${JOBSCRIPT_TEMPLATE}" ]]; then
        error "jobscript.sh not found at: ${JOBSCRIPT_TEMPLATE}"
        exit 1
    fi

    # Validate JSON syntax
    if ! jq empty "${MODELS_JSON}" 2>/dev/null; then
        error "models.json contains invalid JSON"
        exit 1
    fi

    # Check if model exists in catalog
    if ! jq -e --arg model "$model_name" '.[$model]' "${MODELS_JSON}" &>/dev/null; then
        error "Model '${model_name}' not found in models.json"
        echo ""
        list_models
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

get_model_config() {
    local model_name=$1
    local field=$2

    jq -r --arg model "$model_name" --arg field "$field" '.[$model][$field]' "${MODELS_JSON}"
}

# ============================================================================
# Job Submission
# ============================================================================

submit_job() {
    local model_name=$1
    local job_duration=$2

    info "Loading model configuration for: ${model_name}"

    local model_path=$(get_model_config "$model_name" "path")
    local max_model_len=$(get_model_config "$model_name" "max_model_len")

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

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--model)
                model_name="$2"
                shift 2
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
                list_models
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

    # Run pre-flight checks
    preflight_checks "$model_name"

    # Submit job
    submit_job "$model_name" "$job_duration"

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
