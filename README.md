# Alvis vLLM Connection Automation

Automate the process of connecting to Chalmers Alvis AI supercompute cluster, requesting compute resources, launching a vLLM server, and establishing an SSH tunnel to access it locally.

## Quick Start

```bash
cd ~/alvis-vllm
./vllm-connect.sh
```

The script will:
1. Submit a SLURM job to Alvis
2. Wait for the job to start
3. Wait for the vLLM server to be ready
4. Establish an SSH tunnel
5. Stream logs to your terminal

Access the server at: **http://localhost:58000**

Press `Ctrl+C` to stop and cleanup.

## Installation

```bash
# Clone or copy files to your home directory
mkdir -p ~/alvis-vllm
cd ~/alvis-vllm

# Copy all files:
# - vllm-connect.sh
# - jobscript.sh
# - models.json

# Make the main script executable
chmod +x vllm-connect.sh
```

### Optional: Add alias to your shell profile

```bash
# Add to ~/.zshrc or ~/.bashrc
alias vllm-connect='~/alvis-vllm/vllm-connect.sh'
```

## Usage

### Basic Usage

```bash
# Use default model (gpt-oss-20b) for 1 hour
./vllm-connect.sh

# Specify model and duration
./vllm-connect.sh -m gpt-oss-20b -t 2:00:00

# List available models
./vllm-connect.sh --list-models

# Show help
./vllm-connect.sh --help
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-m, --model MODEL_NAME` | Model to use | `gpt-oss-20b` |
| `-t, --time DURATION` | Job duration (HH:MM:SS) | `1:00:00` |
| `-h, --help` | Show help message | - |
| `--list-models` | List available models | - |

## Adding New Models

Edit [models.json](models.json) to add new models:

```json
{
  "model-name": {
    "path": "/path/to/model/on/alvis",
    "max_model_len": 8192,
    "description": "Model description"
  }
}
```

**Fields:**
- `path`: Full path to the model on Alvis filesystem
- `max_model_len`: Maximum context length for the model
- `description`: Human-readable description (optional)

## Example Output

### Successful Connection

```
[INFO] Alvis vLLM Connection Automation
[INFO] ================================

[INFO] Running pre-flight checks...
[INFO] Checking SSH connection to alvis2...
✓ SSH connection successful
[INFO] Loading model configuration for: gpt-oss-20b
[INFO] Model path: /mimer/NOBACKUP/Datasets/LLM/huggingface/hub/models--openai--gpt-oss-20b/snapshots/...
[INFO] Max model length: 10000
[INFO] Submitting job (duration: 1:00:00)...
[INFO] Job submitted: 5382685
[INFO] Waiting for job to start...
✓ Job is running on node: alvis7-07

[INFO] Waiting for server address...
✓ Server address: alvis7-07:41084

[INFO] Establishing SSH tunnel (local port 58000)...
[INFO] Testing connection...
✓ Connection successful! Server available at http://localhost:58000

[INFO] Streaming logs (Ctrl+C to stop and cleanup)...

[VLLM] INFO: Started server process [12345]
[VLLM] INFO: Waiting for application startup.
[VLLM] INFO: Application startup complete.
[VLLM] INFO:     Uvicorn running on http://0.0.0.0:41084
^C
[INFO] Cleaning up...
[INFO] Cancelling job 5382685...
✓ Cleaned up job 5382685
```

## Testing the Connection

Once connected, test with curl:

```bash
# List available models
curl http://localhost:58000/v1/models

# Generate text
curl http://localhost:58000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss-20b",
    "prompt": "Once upon a time",
    "max_tokens": 50
  }'
```

## Project Structure

```
~/alvis-vllm/
├── vllm-connect.sh    # Main automation script
├── jobscript.sh       # SLURM job script template
├── models.json        # Model catalog with paths and configurations
├── README.md          # This file
└── ~/.vllm-session    # Runtime session info (auto-generated)
```

## Troubleshooting

### Port 58000 already in use

```bash
# Find and kill the process using the port
lsof -ti:58000 | xargs kill -9

# Or use a different port (requires editing the script)
```

### SSH connection fails

Ensure your SSH config has the Alvis host configured:

```bash
# ~/.ssh/config should have:
Host alvis2
    HostName alvis2.c3se.chalmers.se
    User pradas
```

### Job fails to start

Check SLURM queue status:

```bash
ssh alvis2 "squeue -u pradas"
```

Check account balance:

```bash
ssh alvis2 "projinfo NAISS2025-22-1522"
```

### vLLM fails to start

The script will display error logs from `vllm.err`. Common issues:
- Model path is incorrect
- Insufficient GPU memory
- Model files are corrupted

## Requirements

### Local System
- `bash` (macOS/Linux)
- `ssh` with key authentication configured
- `curl` for testing connections
- `jq` for JSON parsing (`brew install jq`)
- `lsof` for port checking

### Alvis Cluster
- SSH access configured
- Account: NAISS2025-22-1522
- `find_ports` utility (provided by Alvis)
- Apptainer container: `/apps/containers/vLLM/vllm-0.11.0.sif`

## Session Information

The script saves session information to `~/.vllm-session`:

```
JOB_ID=5382685
NODE=alvis7-07
PORT=41084
LOCAL_PORT=58000
TMPDIR=/path/to/tmpdir
MODEL=gpt-oss-20b
STARTED=2024-11-21T10:30:00
```

## Future Enhancements

- [ ] Automatic model discovery by scanning Alvis filesystem
- [ ] Session recovery (reconnect to existing jobs)
- [ ] Multi-job management
- [ ] Configuration file for defaults (~/.alvis-vllm.conf)
- [ ] Support for multiple simultaneous connections

## License

Internal use for Chalmers University Alvis cluster.
