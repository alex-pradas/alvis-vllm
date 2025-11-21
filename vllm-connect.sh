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
    echo -e "${BLUE}[$(timestamp)]${NC} ${GREEN}✓${NC} $*"
}

error() {
    echo -e "${BLUE}[$(timestamp)]${NC} ${RED}[ERROR]${NC} $*" >&2
}

warning() {
    echo -e "${BLUE}[$(timestamp)]${NC} ${YELLOW}[WARN]${NC} $*"
}

# Cleanup function - called on exit
cleanup() {
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
    if ! submit_output=$(ssh "${SSH_HOST}" "cat > /tmp/jobscript_$$.sh && sbatch /tmp/jobscript_$$.sh && rm /tmp/jobscript_$$.sh" < "${temp_jobscript}" 2>&1); then
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
    info "Waiting for job to start..."

    local elapsed=0
    local node_name=""

    while [[ $elapsed -lt $JOB_START_TIMEOUT ]]; do
        # Check job status
        local job_info
        job_info=$(ssh "${SSH_HOST}" "squeue -j ${JOB_ID} -h -o '%T %N'" 2>/dev/null || echo "")

        if [[ -z "$job_info" ]]; then
            error "Job ${JOB_ID} not found in queue. It may have failed immediately."
            exit 1
        fi

        local job_state=$(echo "$job_info" | awk '{print $1}')
        node_name=$(echo "$job_info" | awk '{print $2}')

        if [[ "$job_state" == "RUNNING" ]]; then
            success "Job is running on node: ${node_name}"
            echo "$node_name"
            return 0
        fi

        printf "\r${BLUE}[$(timestamp)]${NC} ${BLUE}[INFO]${NC} Waiting for job to start... (${elapsed}s/${JOB_START_TIMEOUT}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    error "Job did not start within ${JOB_START_TIMEOUT} seconds"
    exit 1
}

# ============================================================================
# Server Ready Detection
# ============================================================================

wait_for_server_address() {
    local node_name=$1

    info "Waiting for server address..."

    local elapsed=0
    local server_address=""

    # First, discover the TMPDIR for this job
    local tmpdir
    tmpdir=$(ssh "${SSH_HOST}" "squeue -j ${JOB_ID} -h -o '%Z'" 2>/dev/null || echo "")

    if [[ -z "$tmpdir" ]]; then
        error "Could not determine TMPDIR for job ${JOB_ID}"
        exit 1
    fi

    while [[ $elapsed -lt $SERVER_READY_TIMEOUT ]]; do
        # Try to read server_address.txt from remote TMPDIR
        server_address=$(ssh "${SSH_HOST}" "cat ${tmpdir}/server_address.txt 2>/dev/null" || echo "")

        if [[ -n "$server_address" ]]; then
            success "Server address: ${server_address}"
            echo "${server_address}|${tmpdir}"
            return 0
        fi

        printf "\r${BLUE}[$(timestamp)]${NC} ${BLUE}[INFO]${NC} Waiting for server address... (${elapsed}s/${SERVER_READY_TIMEOUT}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    error "Server address not available within ${SERVER_READY_TIMEOUT} seconds"

    # Try to show error logs
    info "Checking vLLM error log..."
    ssh "${SSH_HOST}" "cat ${tmpdir}/vllm.err 2>/dev/null" || echo "Could not read error log"

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

    # Establish tunnel with automatic host key acceptance for new hosts
    ssh -f -N -L "${LOCAL_PORT}:${node_name}:${remote_port}" \
        -o StrictHostKeyChecking=accept-new \
        -o ExitOnForwardFailure=yes \
        -J "${SSH_JUMP_HOST}" \
        "${SSH_USER}@${node_name}" &

    SSH_TUNNEL_PID=$!

    # Wait a moment for tunnel to establish
    sleep 2

    # Check if tunnel process is still running
    if ! kill -0 "${SSH_TUNNEL_PID}" 2>/dev/null; then
        error "SSH tunnel failed to establish"
        exit 1
    fi

    # Test connection
    info "Testing connection..."

    local retries=0
    local max_retries=10

    while [[ $retries -lt $max_retries ]]; do
        if curl -s --max-time "${CONNECTION_TEST_TIMEOUT}" "http://localhost:${LOCAL_PORT}/v1/models" >/dev/null 2>&1; then
            success "Connection successful! Server available at http://localhost:${LOCAL_PORT}"
            return 0
        fi

        retries=$((retries + 1))
        sleep 2
    done

    error "Connection test failed after ${max_retries} attempts"
    exit 1
}

# ============================================================================
# Log Streaming
# ============================================================================

stream_logs() {
    local tmpdir=$1
    local node_name=$2

    info "Streaming logs (Ctrl+C to stop and cleanup)..."
    echo ""

    # Stream logs in background
    (
        ssh "${SSH_HOST}" "tail -f ${tmpdir}/vllm.out ${tmpdir}/vllm.err 2>/dev/null" | while IFS= read -r line; do
            # Simple heuristic: if line contains ERROR, WARNING, or comes from stderr pattern, color it red
            if [[ "$line" =~ ERROR|WARNING|Exception ]]; then
                echo -e "${RED}[VLLM]${NC} $line"
            else
                echo -e "${GREEN}[VLLM]${NC} $line"
            fi
        done
    ) &

    LOG_STREAM_PID=$!

    # Wait for log streaming process
    wait "${LOG_STREAM_PID}"
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
    local node_name
    node_name=$(wait_for_job_start)
    echo ""

    # Wait for server to be ready
    local server_info
    server_info=$(wait_for_server_address "$node_name")
    local server_address=$(echo "$server_info" | cut -d'|' -f1)
    local tmpdir=$(echo "$server_info" | cut -d'|' -f2)
    echo ""

    # Parse server address
    local remote_port=$(echo "$server_address" | cut -d: -f2)

    # Establish SSH tunnel
    establish_tunnel "$server_address"
    echo ""

    # Save session information
    save_session "$model_name" "$node_name" "$remote_port" "$tmpdir"

    # Stream logs (blocks until Ctrl+C)
    stream_logs "$tmpdir" "$node_name"
}

# Run main function
main "$@"
