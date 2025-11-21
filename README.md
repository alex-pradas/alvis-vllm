# Alvis vLLM Connection Automation

Automate the process of connecting to Chalmers Alvis AI supercompute cluster, requesting compute resources, launching a vLLM server, and establishing an SSH tunnel to access it locally.

## ✨ What's New in v0.2.0

- 🤖 **Automatic Model Discovery** - Finds 40+ models from Alvis HuggingFace cache automatically
- 🎯 **Interactive Selection** - User-friendly menu with `-i/--interactive` flag
- 📊 **Grouped Model Listing** - Clean, color-coded display organized by provider
- ⚙️ **Smart Defaults** - Intelligent `max_model_len` based on model size
- 🎨 **Improved UI** - Compact format with continuous numbering

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
| `-i, --interactive` | Interactive model selection menu | - |
| `-t, --time DURATION` | Job duration (HH:MM:SS) | `1:00:00` |
| `-h, --help` | Show help message | - |
| `--list-models` | List available models (auto-discovered) | - |

### Interactive Model Selection

Use the `-i` flag to browse models in a user-friendly menu:

```bash
./vllm-connect.sh -i
```

You'll see models grouped by provider with continuous numbering:

```
HuggingFaceTB:
   1. SmolLM2-135M (max: 8192)
   2. SmolLM2-135M-Instruct (max: 8192)

Qwen:
   6. Qwen2-0.5B (max: 8192)
   7. Qwen2.5-0.5B-Instruct (max: 8192)

unsloth:
  24. Llama-3.2-1B-Instruct (max: 8192)
  25. Llama-3.2-3B-Instruct (max: 8192)
  ...

Select model (1-40):
```

## Model Configuration

### Automatic Discovery

Models are automatically discovered from `/mimer/NOBACKUP/Datasets/LLM/huggingface/hub/` on Alvis. The script:
- Scans for all available models in HuggingFace cache format
- Selects the latest snapshot for each model
- Applies intelligent default `max_model_len` based on model size:

| Model Size | Default max_model_len |
|------------|----------------------|
| 1B-7B      | 4096                 |
| 8B-13B     | 8192                 |
| 14B-20B    | 10000                |
| 21B-34B    | 16384                |
| 35B+       | 32768                |

### Manual Overrides

The [models.json](models.json) file is now used for **overrides only**. Edit it to customize specific models:

```json
{
  "_comment": "This file is used for OVERRIDES ONLY",
  "org/model-name": {
    "path": "/custom/path/to/model",
    "max_model_len": 10000,
    "description": "Custom description"
  }
}
```

**Use cases:**
- Override auto-discovered `max_model_len`
- Specify custom model paths
- Add descriptive names
- Configure models not in the cache

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

## Version History

### v0.2.0 (Current)
- ✅ Automatic model discovery from Alvis HuggingFace cache
- ✅ Interactive model selection menu with `-i` flag
- ✅ Grouped, color-coded model listing by provider
- ✅ Intelligent default `max_model_len` based on model size
- ✅ Hybrid configuration (models.json for overrides only)
- ✅ Bash 3.2 compatibility

### v0.1.0
- ✅ Basic vLLM connection automation
- ✅ Real-time output streaming with timestamps
- ✅ Automatic SSH tunneling
- ✅ SLURM job management
- ✅ Manual model configuration

## Future Enhancements

- [ ] Session recovery (reconnect to existing jobs)
- [ ] Multi-job management
- [ ] Configuration file for defaults (~/.alvis-vllm.conf)
- [ ] Support for multiple simultaneous connections
- [ ] Model performance metrics and usage tracking

## License

Internal use for Chalmers University Alvis cluster.
