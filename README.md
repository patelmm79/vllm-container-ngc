# vLLM NGC Container - DeepSeek-R1

A containerized vLLM inference server using NVIDIA's NGC container that serves the DeepSeek-R1-Distill-Qwen-1.5B model (1.5B parameters) with optimized cold start performance through build-time model pre-warming.

## Overview

This project creates "pre-warmed" Docker containers where the expensive model loading and initialization steps are performed during the Docker build process rather than at runtime. This approach significantly reduces cold start times for serverless deployments like Google Cloud Run.

### Key Features

- **Centralized Configuration**: All model and deployment settings in one `config.env` file - change models easily
- **Pre-warmed Model Loading**: Model downloads and initialization happen during build time
- **Offline Runtime**: Container runs completely offline without Hugging Face Hub access
- **OpenAI-Compatible API**: Serves model via vLLM's OpenAI-compatible API on port 8000
- **Optimized for Cloud Run**: Default configuration tuned for fast cold starts with auto-scaling
- **Flexible torch.compile Settings**: Configurable compilation level for different deployment scenarios
- **Secure Token Management**: Hugging Face tokens handled securely via Google Secret Manager

## Architecture

The project consists of three main components:

### 1. Dockerfile

Builds a container based on `nvcr.io/nvidia/vllm:25.10-py3` (NVIDIA NGC) that:
- Loads model configuration from `config.env` for centralized management
- Downloads the specified model during build time using a Hugging Face token
- Configures the container to run offline (no Hugging Face Hub access at runtime)
- Sets up custom entrypoint for optional pre-warming when torch.compile is enabled
- Serves the model via OpenAI-compatible API on port 8000

### 2. Cloud Build Configuration

`cloudbuild.yaml` orchestrates the build process using:
- Google Cloud Build with `E2_HIGHCPU_8` machine type
- Docker buildx for advanced build features
- Secure injection of `HF_TOKEN` from Google Secret Manager
- Pushes to Google Artifact Registry at `us-central1-docker.pkg.dev/${PROJECT_ID}/vllm-deepseek-r1-repo/vllm-deepseek-r1-1-5b`

### 3. Documentation

- `CLAUDE.md`: Comprehensive project documentation and configuration details
- `GEMINI.md`: Detailed build instructions and prerequisites

## Quick Start

### Prerequisites

1. Google Cloud Project with Cloud Build API and Secret Manager API enabled
2. `gcloud` CLI installed and authenticated
3. Hugging Face token with access to the DeepSeek-R1 model stored in Google Secret Manager (secret name: `HF_TOKEN`)

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

**Important**: Do NOT pass `HF_TOKEN` via `--substitutions`. The token is automatically injected from Secret Manager.

## Configuration

### Centralized Model Configuration

All model and deployment configuration is centralized in `config.env`. To change models, simply edit this file:

```bash
# config.env
MODEL_NAME=deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B
HF_CACHE_DIR=models--deepseek-ai--DeepSeek-R1-Distill-Qwen-1.5B
SERVICE_NAME=vllm-deepseek-r1-1-5b
ARTIFACT_REGISTRY_REPO=vllm-deepseek-r1-repo
ARTIFACT_REGISTRY_IMAGE=vllm-deepseek-r1-1-5b
```

See the "Changing Models" section in `CLAUDE.md` for detailed instructions.

### Environment Variables

- `MODEL_NAME`: Hugging Face model identifier (set in `config.env`)
- `HF_CACHE_DIR`: Normalized cache directory name (set in `config.env`)
- `HF_HOME`: Model cache directory (`/model-cache`)
- `HF_TOKEN`: Required for downloading the model from Hugging Face (build time only)
- `HF_HUB_OFFLINE`: Set to `1` in final container to prevent runtime Hub access
- `PORT`: Server port (defaults to 8080 on Cloud Run, 8000 locally)
- `MAX_MODEL_LEN`: Optional model length limit
- `TORCH_CUDA_ARCH_LIST`: CUDA compute capability for target GPU (default: `7.5` for T4)
- `VLLM_TORCH_COMPILE_LEVEL`: torch.compile optimization level (default: `0`)
- `SKIP_PREWARM`: Set to `1` to skip runtime pre-warming (only relevant when `VLLM_TORCH_COMPILE_LEVEL > 0`)

### torch.compile Configuration

**Current Status**: torch.compile is **disabled by default** (`VLLM_TORCH_COMPILE_LEVEL=0`) to optimize for cold start times.

#### Why Disabled?

For Cloud Run deployments with auto-scaling, disabling torch.compile provides better overall performance:

**Trade-offs**:
- ✅ **~60 seconds faster cold starts** (149s → ~90s)
- ✅ **Predictable startup time** - no compilation variance
- ✅ **Better for frequent scaling** - new containers start faster
- ❌ **~10-30% lower throughput** for individual requests
- ❌ **~50-200ms higher per-request latency**

**Key limitation**: torch.compile cache cannot persist across Cloud Run container instances. Each new container must recompile from scratch, adding 60s to every cold start with auto-scaling.

#### When to Enable torch.compile

If you have **sustained, consistent traffic**, you can enable torch.compile for better per-request performance:

1. Set `VLLM_TORCH_COMPILE_LEVEL=1` in the Dockerfile
2. Configure Cloud Run with `minInstances: 2-3` to keep containers warm
3. Most requests will hit warm containers (avoiding the 60s compilation cost)

#### Configuration Options

- `VLLM_TORCH_COMPILE_LEVEL=0`: **Disabled (default)** - Fastest cold starts, recommended for auto-scaling
- `VLLM_TORCH_COMPILE_LEVEL=1`: Enabled with basic compilation - Use with `minInstances > 0` for sustained traffic
- `SKIP_PREWARM=1`: Skip pre-warming phase (only relevant when torch.compile is enabled)

## Runtime Configuration

The container serves the model via vLLM's OpenAI-compatible API with these defaults:
- Port: 8080 (Cloud Run) or 8000 (local, configurable via `PORT` env var)
- Model: Specified in `config.env` (default: `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B`, 1.5B parameters)
- Data type: float16
- Optional max model length via `MAX_MODEL_LEN`

## Security

- Hugging Face token is handled securely via Google Secret Manager
- Container runs offline at runtime to prevent unauthorized Hub access
- Model weights are cached during build to avoid runtime downloads

## Project Goals

The primary goal of this project is to containerize DeepSeek-R1-Distill-Qwen-1.5B (1.5B parameters) using NVIDIA's NGC vLLM container for the fastest possible inference, with a focus on minimizing cold start times. The main issue being addressed is the slow initial response after periods of inactivity, which is solved by performing model loading during the build process.

### Current Workflow (Manual)

1. **Build**: Container image is built using `Dockerfile` and triggered manually with `gcloud builds submit`
2. **Monitor**: Build logs in Cloud Build are monitored manually for errors
3. **Deploy**: Upon successful build, the new container image is deployed manually to Google Cloud Run

### Desired Automation and Testing

- **Automated Deployment**: Automatically deploy the container to Cloud Run when Cloud Build completes successfully
- **Post-Deployment Test**: Run automated tests that call the Cloud Run service endpoint to verify the LLM is responsive and provides valid output

## Testing

The project includes automated tests in `test_endpoint.py` that verify the deployed Cloud Run service.

### Testing with gcloud CLI (Recommended)

If you have `gcloud` CLI installed and configured:

```bash
# Run tests (automatically fetches service URL and auth token)
pytest test_endpoint.py -v
```

### Testing without gcloud CLI

If you don't have `gcloud` installed locally (e.g., testing from Windows without SDK):

1. **Create test configuration file**:
   ```bash
   cp .env.test.example .env.test
   ```

2. **Fill in the values in `.env.test`**:
   - Get `SERVICE_URL` from [Cloud Console](https://console.cloud.google.com/run) or run this command on a machine with gcloud:
     ```bash
     gcloud run services describe vllm-deepseek-r1-1-5b --platform managed --region us-central1 --format "value(status.url)"
     ```
   - Get `AUTH_TOKEN` by running this command on a machine with gcloud:
     ```bash
     gcloud auth print-identity-token
     ```

3. **Run tests using the helper script**:

   **PowerShell** (Recommended for Windows):
   ```powershell
   .\test_local.ps1
   ```

   **Batch** (Alternative):
   ```batch
   test_local.bat
   ```

   **Manual** (Any platform):
   ```bash
   # Set environment variables and run pytest
   export SERVICE_URL="your-service-url"
   export AUTH_TOKEN="your-auth-token"
   pytest test_endpoint.py -v
   ```

### What the Tests Verify

- `/v1/models` endpoint returns the correct model
- `/v1/completions` endpoint generates text successfully
- Service is responsive and returns valid JSON responses

## License

This project is provided as-is for containerizing and deploying vLLM inference servers.
