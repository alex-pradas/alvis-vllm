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
# Output streams to vllm.out (stdout) and vllm.err (stderr) for real-time monitoring
vllm_opts="--tensor-parallel-size=${SLURM_GPUS_ON_NODE} --max-model-len={{MAX_MODEL_LEN}}"

echo "Starting vLLM server..."
echo "Output will be written to: ${TMPDIR}/vllm.out and ${TMPDIR}/vllm.err"
apptainer exec ${SIF_IMAGE} vllm serve ${HF_MODEL} \
   --port ${API_PORT} ${vllm_opts} \
   --served-model-name $MODEL_NAME \
   > vllm.out 2> vllm.err &
VLLM_PID=$!
sleep 20

# wait at most 10 min for the model to start, otherwise abort
if timeout 600 bash -c "tail -f vllm.err | grep -q 'Application startup complete'"; then
    echo "vLLM server started successfully"
    echo "========================================================================"
    echo "vLLM server is running. Waiting for job to complete..."
    wait $VLLM_PID
else
    echo "vLLM doesn't seem to start, aborting"
    kill $VLLM_PID 2>/dev/null
    exit 1
fi
