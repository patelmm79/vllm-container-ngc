# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a containerized vLLM inference server project that serves the Google Gemma 3.1B Instruct model. The project focuses on creating "pre-warmed" containers where the expensive model loading step is performed during the Docker build process rather than at runtime.

## Architecture

The project consists of three main components:

1. **Dockerfile**: Builds a container based on `vllm/vllm-openai:v0.9.0` that:
   - Downloads the `google/gemma-3-1b-it` model during build time using a Hugging Face token
   - Pre-warms the model by starting vLLM server, making a test request, then stopping it
   - Includes comprehensive debug logging and timeout handling (300 second timeout with progress updates)
   - Captures and displays vLLM server logs for troubleshooting
   - Sets up the container to run offline (no Hugging Face Hub access at runtime)
   - Serves the model via OpenAI-compatible API on port 8000

2. **Cloud Build Configuration** (`cloudbuild.yaml`): Orchestrates the build process using:
   - Google Cloud Build with `E2_HIGHCPU_8` machine type
   - Docker buildx for advanced build features
   - Secure injection of `HF_TOKEN` from Google Secret Manager
   - Pushes to Google Artifact Registry at `us-central1-docker.pkg.dev/${PROJECT_ID}/vllm-gemma-3-1b-it-repo/vllm-gemma-3-1b-it`

3. **Documentation**: `GEMINI.md` provides detailed build instructions and prerequisites

## Build Commands

### Local Development
```bash
# Build locally (requires HF_TOKEN environment variable)
docker build --secret id=HF_TOKEN --tag vllm-gemma .
```

### Production Build
```bash
# Build using Google Cloud Build
gcloud builds submit --config cloudbuild.yaml
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

## Runtime Configuration

The container serves the model via vLLM's OpenAI-compatible API with these defaults:
- Port: 8000 (configurable via `PORT` env var)
- Model: `google/gemma-3-1b-it`
- Data type: float32
- Optional max model length via `MAX_MODEL_LEN`

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