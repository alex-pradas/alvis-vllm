# Alvis vLLM Connection Automation - Requirements

## Overview
Create a system to automate the process of connecting to Chalmers Alvis AI supercompute cluster, requesting compute resources, launching a vLLM server, and establishing an SSH tunnel to access it from a local Mac.

## Project Structure
```
~/alvis-vllm/
├── vllm-connect.sh          # Main automation script (bash)
├── jobscript.sh             # SLURM job script template
├── models.json              # Model catalog with paths and configurations
└── .vllm-session           # Runtime session info (auto-generated)
```

## User Workflow
The user should be able to run:
```bash
cd ~/alvis-vllm
./vllm-connect.sh [OPTIONS]
```

And the script handles everything from job submission to establishing the tunnel.

## Components

### 1. Main Script: `vllm-connect.sh`

#### Command-line Interface
```bash
./vllm-connect.sh [OPTIONS]

OPTIONS:
  -m, --model MODEL_NAME    Model to use (default: gpt-oss-20b)
  -t, --time DURATION       Job duration in HH:MM:SS format (default: 1:00:00)
  -h, --help               Show help message
  --list-models            List available models from models.json
```

#### Workflow Steps

1. **Pre-flight Checks**
   - Verify SSH connection to alvis2 works
   - Verify required files exist (jobscript.sh, models.json)
   - Check if local port 58000 is available
   - Validate model name exists in models.json

2. **Model Selection**
   - Read from `models.json` to get model path and configuration
   - Substitute model information into jobscript.sh

3. **Job Submission**
   - Create temporary directory on Alvis using `$TMPDIR` environment variable
   - Copy jobscript.sh to remote temporary directory
   - Submit job via `sbatch` and capture job ID
   - Display: "Job submitted: [JOB_ID]"

4. **Job Monitoring**
   - Poll `squeue -u pradas` every 5 seconds
   - Check if job ID appears with state "RUNNING"
   - Display: "Waiting for job to start..." (with spinner or dots)
   - Timeout after 10 minutes if job doesn't start
   - Display: "Job is running on node [NODE_NAME]"

5. **Server Ready Detection**
   - Wait for `server_address.txt` to appear in the remote $TMPDIR
   - Poll via SSH every 5 seconds: `ssh alvis2 "cat $TMPDIR/server_address.txt"`
   - Timeout after 10 minutes
   - Parse the file to extract: `HOSTNAME:PORT`
   - Display: "Server address: [HOSTNAME:PORT]"

6. **Tunnel Establishment**
   - Establish SSH tunnel: `ssh -L 58000:HOSTNAME:PORT -J pradas@alvis2.c3se.chalmers.se pradas@HOSTNAME`
   - Handle first-time connection (auto-accept host key)
   - Test connection: `curl http://localhost:58000/v1/models`
   - Display: "✓ Connection successful! Server available at http://localhost:58000"

7. **Log Streaming**
   - In the background, tail both `vllm.out` and `vllm.err` from remote $TMPDIR
   - Stream to local terminal with prefixes:
     - `[VLLM OUT]` for stdout
     - `[VLLM ERR]` for stderr
   - If vLLM crashes or exits, detect it and display error

8. **Session Persistence**
   - Write session info to `.vllm-session`:
     ```
     JOB_ID=5382685
     NODE=alvis7-07
     PORT=41084
     LOCAL_PORT=58000
     TMPDIR=/path/to/tmpdir
     MODEL=gpt-oss-20b
     STARTED=2024-11-21T10:30:00
     ```

9. **Cleanup on Exit**
   - On Ctrl+C or script termination:
     - Cancel SLURM job: `scancel [JOB_ID]`
     - Close SSH tunnel
     - Display: "Cleaned up job [JOB_ID]"

#### Error Handling

- **Job fails to start within 10 minutes**: Cancel job, display error, exit
- **vLLM fails to start within 10 minutes**: Cancel job, display error from vllm.err, exit
- **SSH tunnel fails**: Cancel job, display error, exit
- **Port 58000 already in use**: Display error suggesting to kill existing process, exit
- **Model not found in models.json**: Display error and list available models, exit

### 2. SLURM Job Script: `jobscript.sh`

The script should be a template with placeholders that get substituted by the main script:

```bash
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
vllm_opts="--tensor-parallel-size=${SLURM_GPUS_ON_NODE} --max-model-len={{MAX_MODEL_LEN}}"

echo "Starting server node"
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
```

**Placeholders to substitute:**
- `{{TIME}}` - Job duration
- `{{MODEL_PATH}}` - Full path to model
- `{{MAX_MODEL_LEN}}` - Maximum model length from models.json

### 3. Model Catalog: `models.json`

```json
{
  "gpt-oss-20b": {
    "path": "/mimer/NOBACKUP/Datasets/LLM/huggingface/hub/models--openai--gpt-oss-20b/snapshots/cbf31f62664d4b1360b3a78427f7b3c3ed8f0fa8/",
    "max_model_len": 10000,
    "description": "GPT OSS 20B model"
  }
}
```

**Schema:**
- `path`: Full path to model on Alvis filesystem
- `max_model_len`: Maximum context length
- `description`: Human-readable description (optional)

## Technical Requirements

### SSH Configuration
- SSH key authentication is configured for `alvis2`
- Compute nodes may require accepting host key on first connection
- Use SSH config alias: `alvis2` (already configured in ~/.ssh/config)
- Username on Alvis: `pradas`
- Full jump host path: `pradas@alvis2.c3se.chalmers.se`

### Port Configuration
- Local port: `58000` (hardcoded, must be available)
- Remote port: Dynamic, provided by `find_ports` function on Alvis
- Remote port is written to `server_address.txt` in format: `hostname:port`

### Timeouts
- Job start timeout: 10 minutes
- Server ready timeout: 10 minutes
- Connection test timeout: 30 seconds

### Dependencies
- `curl` - for testing connection
- `ssh` - for remote connections
- `jq` - for parsing JSON (models.json)
- Standard bash utilities: `grep`, `awk`, `sed`, etc.

## User Experience

### Successful Run Example
```
$ ./vllm-connect.sh -m gpt-oss-20b -t 2:00:00

[INFO] Checking SSH connection to alvis2...
[INFO] SSH connection successful
[INFO] Loading model configuration for: gpt-oss-20b
[INFO] Model path: /mimer/NOBACKUP/Datasets/LLM/huggingface/hub/models--openai--gpt-oss-20b/snapshots/...
[INFO] Submitting job (duration: 2:00:00)...
Job submitted: 5382685
[INFO] Waiting for job to start...
[INFO] Job is running on node: alvis7-07
[INFO] Waiting for server address...
[INFO] Server address: alvis7-07:41084
[INFO] Establishing SSH tunnel (local port 58000)...
[INFO] Testing connection...
✓ Connection successful! Server available at http://localhost:58000

[INFO] Streaming logs (Ctrl+C to stop and cleanup)...
[VLLM OUT] INFO: Started server process [12345]
[VLLM OUT] INFO: Waiting for application startup.
[VLLM OUT] INFO: Application startup complete.
[VLLM ERR] INFO:     Uvicorn running on http://0.0.0.0:41084
^C
[INFO] Cancelling job 5382685...
[INFO] Cleaned up successfully
```

### Error Example
```
$ ./vllm-connect.sh -m nonexistent-model

[ERROR] Model 'nonexistent-model' not found in models.json
[INFO] Available models:
  - gpt-oss-20b: GPT OSS 20B model
```

## Future Enhancements (Not Required Now)

- Add note in code: "TODO: Implement automatic model discovery by scanning /mimer/NOBACKUP/Datasets/LLM/huggingface/hub/"
- Multi-job management (check for existing jobs before submitting)
- Session recovery (reconnect to existing job)
- Configuration file for defaults (~/.alvis-vllm.conf)

## Testing Checklist

The script should handle:
- [ ] Clean run with default model
- [ ] Custom model selection
- [ ] Custom time duration
- [ ] Model not found in catalog
- [ ] Port 58000 already in use
- [ ] SSH connection failure
- [ ] Job submission failure
- [ ] Job timeout (doesn't start)
- [ ] vLLM startup failure
- [ ] Graceful cleanup on Ctrl+C
- [ ] First-time connection to new compute node (host key acceptance)

## Installation

User should be able to:
```bash
mkdir -p ~/alvis-vllm
cd ~/alvis-vllm
# Copy all files
chmod +x vllm-connect.sh
```

Add to their shell profile (optional):
```bash
alias vllm-connect='~/alvis-vllm/vllm-connect.sh'
```

## Notes

- All temporary files on Alvis should be created in `$TMPDIR` (SLURM provides this)
- The script must handle the SLURM temporary directory being unique per job
- Log streaming should flush output immediately (unbuffered)
- The script should be resilient to network hiccups (SSH may disconnect)