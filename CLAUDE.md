# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a containerized vLLM inference server project that serves the Google Gemma 3.1B Instruct model. The project focuses on creating "pre-warmed" containers where the expensive model loading step is performed during the Docker build process rather than at runtime. The goal is to minimize cold start times for serverless deployments on Google Cloud Run.

## Architecture

The project consists of five main components:

1. **Dockerfile**: Builds a container based on `vllm/vllm-openai:latest` that:
   - Downloads the `google/gemma-3-1b-it` model during build time using a Hugging Face token
   - Configures the runtime environment to run offline (no Hugging Face Hub access)
   - Sets up custom entrypoint for pre-warming when torch.compile is enabled
   - Serves the model via OpenAI-compatible API on port 8000

2. **Runtime Entrypoint** (`entrypoint.sh` + `prewarm_compile.py`):
   - `entrypoint.sh`: Custom startup script with comprehensive timing instrumentation
   - Starts vLLM server in background and manages its lifecycle
   - Conditionally runs pre-warming if `VLLM_TORCH_COMPILE_LEVEL > 0`
   - `prewarm_compile.py`: Makes test requests with various input lengths (128, 256, 512, 1024, 2048 tokens) to populate torch.compile cache
   - Keeps server running in foreground for normal operation

3. **Cloud Build Pipeline** (`cloudbuild.yaml`): Multi-step CI/CD pipeline with:
   - **Build step**: Uses Docker buildx with `E2_HIGHCPU_8` machine, securely injects `HF_TOKEN` from Secret Manager
   - **Deploy step**: Automatically deploys to Cloud Run (`vllm-gemma-3-1b-it` service) with GPU configuration (8 CPU, 32Gi memory, 1x nvidia-l4)
   - **Test step**: Installs dependencies and runs pytest tests against deployed service
   - Pushes to Google Artifact Registry at `us-central1-docker.pkg.dev/${PROJECT_ID}/vllm-gemma-3-1b-it-repo/vllm-gemma-3-1b-it`

4. **Testing Infrastructure**:
   - `test_endpoint.py`: Pytest-based tests that verify `/v1/models` and `/v1/completions` endpoints
   - `test_endpoint.sh`: Bash-based health check script (alternative to pytest)
   - Tests retrieve Cloud Run service URL dynamically and verify model responsiveness
   - `requirements-test.txt`: Test dependencies (pytest, requests)

5. **Build Notification Handler** (`build-notification-handler/main.py`):
   - Cloud Function that responds to Cloud Build Pub/Sub notifications
   - Fetches logs for failed builds from Cloud Logging
   - Prepared for integration with Gemini API for automated failure analysis (commented out)

## Build Commands

### Local Development
```bash
# Build locally (requires HF_TOKEN environment variable)
docker build --secret id=HF_TOKEN --tag vllm-gemma .

# Run locally
docker run -p 8000:8000 vllm-gemma
```

### Production Build and Deploy
```bash
# Build, deploy to Cloud Run, and run tests (all automated via cloudbuild.yaml)
gcloud builds submit --config cloudbuild.yaml
```

**Important**: Do NOT pass `HF_TOKEN` via `--substitutions`. The token is automatically injected from Secret Manager.

### Testing
```bash
# Run tests locally (requires Cloud Run service to be deployed)
pytest test_endpoint.py

# Or use the bash script
./test_endpoint.sh
```

## Key Environment Variables

- `MODEL_NAME`: Set to `google/gemma-3-1b-it`
- `HF_HOME`: Model cache directory (`/model-cache`)
- `HF_TOKEN`: Required for downloading the model from Hugging Face
- `HF_HUB_OFFLINE`: Set to `1` in final container to prevent runtime Hub access
- `PORT`: Server port (defaults to 8000)
- `MAX_MODEL_LEN`: Optional model length limit
- `TORCH_CUDA_ARCH_LIST`: CUDA compute capability for target GPU (default: `7.5` for T4)
  - Set as a build argument in both Dockerfile and Cloud Build configuration
  - Prevents PyTorch from compiling kernels for all visible GPU architectures
  - Significantly reduces compilation time during build and runtime
  - Common values: `7.5` (T4), `7.0` (V100), `8.0` (A100), `8.6` (RTX 3090/4090)
- `VLLM_TORCH_COMPILE_LEVEL`: torch.compile optimization level (default: `0`)
  - `0`: **Disabled (default)** - Fastest cold start, no compilation overhead (~60s faster startup)
  - `1`: Basic compilation - Better throughput but adds ~60s to every cold start
  - `2-3`: More aggressive optimization (longer compilation, higher throughput)
  - **Note**: For Cloud Run with auto-scaling, keeping this at `0` is recommended since torch.compile cache cannot persist across container instances
- `SKIP_PREWARM`: Set to `1` to skip the runtime pre-warming phase (only relevant when `VLLM_TORCH_COMPILE_LEVEL > 0`)
- `TORCH_DISTRIBUTED_DEBUG`: Set to `OFF` to suppress c10d warnings about destroy_process_group()
- `OTEL_SDK_DISABLED`: Set to `true` to disable OpenTelemetry and prevent trace context warnings

## Runtime Configuration

The container serves the model via vLLM's OpenAI-compatible API with these defaults:
- Port: 8000 (configurable via `PORT` env var)
- Model: `google/gemma-3-1b-it`
- Data type: float16 (configured in `entrypoint.sh`)
- GPU memory utilization: 0.95
- Max concurrent sequences: 8
- Optional max model length via `MAX_MODEL_LEN`

### Cloud Run Configuration (from `cloudbuild.yaml`)
- Region: `us-central1`
- CPU: 8 cores
- Memory: 32Gi
- GPU: 1x `nvidia-l4`
- Execution environment: gen2
- Timeout: 600s
- Concurrency: 1 (one request per container instance)
- Min instances: 1 (keeps at least one container warm)
- Max instances: 10
- CPU boost enabled for faster cold starts
- Startup probe: HTTP health check on `/health` endpoint (60 attempts × 10s = 10 minute timeout)

## torch.compile Configuration

**Current Status**: torch.compile is **disabled by default** (`VLLM_TORCH_COMPILE_LEVEL=0`) to optimize for cold start times.

### Why Disabled?

For Cloud Run deployments with auto-scaling, disabling torch.compile provides better overall performance:

**Trade-offs**:
- ✅ **~60 seconds faster cold starts** (149s → ~90s)
- ✅ **Predictable startup time** - no compilation variance
- ✅ **Better for frequent scaling** - new containers start faster
- ❌ **~10-30% lower throughput** for individual requests
- ❌ **~50-200ms higher per-request latency**

**Key limitation**: torch.compile cache cannot persist across Cloud Run container instances. Each new container must recompile from scratch, adding 60s to every cold start with auto-scaling.

### When to Enable torch.compile

If you have **sustained, consistent traffic**, you can enable torch.compile for better per-request performance:

1. Set `VLLM_TORCH_COMPILE_LEVEL=1` in the Dockerfile
2. Configure Cloud Run with `minInstances: 2-3` to keep containers warm
3. Most requests will hit warm containers (avoiding the 60s compilation cost)

### How Pre-warming Works (When Enabled)

When `VLLM_TORCH_COMPILE_LEVEL > 0`, the container implements runtime pre-warming:

1. **On container startup**, the custom entrypoint script (`entrypoint.sh`):
   - Starts the vLLM server in the background
   - Runs the pre-warming script (`prewarm_compile.py`) if torch.compile is enabled
   - Pre-warming script makes test requests with common input lengths (128, 256, 512, 1024, 2048 tokens)
   - Keeps the server running for normal operation

2. **Compiled kernels are cached** in the container filesystem (`~/.triton`, `~/.inductor-cache`) for the lifetime of that container instance

3. **Subsequent requests** within the same container instance use the cached compiled kernels

### Configuration Options

- `VLLM_TORCH_COMPILE_LEVEL=0`: **Disabled (default)** - Fastest cold starts, recommended for auto-scaling
- `VLLM_TORCH_COMPILE_LEVEL=1`: Enabled with basic compilation - Use with `minInstances > 0` for sustained traffic
- `SKIP_PREWARM=1`: Skip pre-warming phase (only relevant when torch.compile is enabled)

## Security Notes

- Hugging Face token is handled securely via Google Secret Manager
- Container runs offline at runtime to prevent unauthorized Hub access
- Model weights are cached during build to avoid runtime downloads

## Development Workflow

### Understanding the Two-Phase Startup

The container has a unique two-phase startup design:

1. **Build-time phase** (Dockerfile): Downloads model weights from Hugging Face Hub
   - Model is cached in `/model-cache` (HF_HOME)
   - Container is configured to run offline after build

2. **Runtime phase** (entrypoint.sh): Starts vLLM server with optional pre-warming
   - Sets system configurations (ulimit, hostname)
   - Starts vLLM server in background
   - Conditionally runs `prewarm_compile.py` if torch.compile is enabled
   - Keeps server running in foreground with timing instrumentation

### Modifying the Container

When making changes to the container:

- **Changing model loading**: Modify Dockerfile (build-time)
- **Changing server startup**: Modify `entrypoint.sh` (runtime)
- **Changing pre-warming behavior**: Modify `prewarm_compile.py` (runtime)
- **Changing deployment config**: Modify `cloudbuild.yaml` deploy step

### Local Testing

For local testing without GPU:
```bash
# Build without GPU dependencies (will fail to run inference but good for testing build)
docker build --secret id=HF_TOKEN --tag vllm-gemma .
```

For testing with GPU (requires NVIDIA Docker):
```bash
# Run with GPU
docker run --gpus all -p 8000:8000 vllm-gemma
```

### Troubleshooting

**Cold start too slow?**
- Check `VLLM_TORCH_COMPILE_LEVEL` - should be `0` for fastest cold starts
- Review `entrypoint.sh` timing logs to identify bottlenecks
- Consider adjusting Cloud Run startup probe settings

**Model not loading?**
- Verify `HF_TOKEN` has access to `google/gemma-3-1b-it` model
- Check build logs for download errors
- Ensure sufficient disk space in build environment

**Tests failing?**
- Verify Cloud Run service name matches `SERVICE_NAME` in `test_endpoint.py`
- Check that service is deployed and healthy before running tests
- Review Cloud Run logs for server errors