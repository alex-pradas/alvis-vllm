#!/usr/bin/env bash
#SBATCH --account NAISS2025-22-1522
#SBATCH --time {{TIME}}
#SBATCH --nodes 1
#SBATCH --gpus-per-node=A40:1

# Navigate to job-specific temporary directory
cd $TMPDIR

export API_PORT=$(find_ports)
export HOSTNAME_PORT=$(hostname):${API_PORT}
echo "Server will run at ${HOSTNAME_PORT}"
echo ${HOSTNAME_PORT} > server_address.txt

module purge

export HF_MODEL="{{MODEL_PATH}}"
export MODEL_NAME=$(echo "$HF_MODEL" | sed -n 's#.*/models--\([^/]*\)--\([^/]*\)/.*#\1/\2#p')
export SIF_IMAGE=/apps/containers/vLLM/vllm-0.11.0.sif

# start vllm server
# Output goes to SLURM output file for easy streaming from login node
vllm_opts="--tensor-parallel-size=${SLURM_GPUS_ON_NODE} --max-model-len={{MAX_MODEL_LEN}}"

echo "Starting vLLM server..."
echo "=== vLLM OUTPUT START ==="
apptainer exec ${SIF_IMAGE} vllm serve ${HF_MODEL} \
   --port ${API_PORT} ${vllm_opts} \
   --served-model-name $MODEL_NAME &
VLLM_PID=$!

echo "========================================================================"
echo "vLLM server is running. Waiting for job to complete..."
echo "The connection script will validate that the API is responding."
echo "========================================================================"

# Wait for vLLM process to complete or until job time limit
wait $VLLM_PID
vllm_exit_code=$?

echo "========================================================================"
echo "vLLM server exited with code: $vllm_exit_code"
echo "========================================================================"

exit $vllm_exit_code
