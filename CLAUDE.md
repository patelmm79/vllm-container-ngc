# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a containerized vLLM inference server project that serves the DeepSeek-R1-Distill-Qwen-1.5B model (1.5B parameters). The project uses NVIDIA's NGC vLLM container and focuses on creating "pre-warmed" containers where the expensive model loading step is performed during the Docker build process rather than at runtime. The goal is to minimize cold start times for serverless deployments on Google Cloud Run.

**Security**: The service includes a FastAPI API gateway that provides API key authentication using Google Secret Manager, protecting the vLLM inference endpoint from unauthorized access.

## Centralized Configuration

**Important**: The model and deployment configuration is centralized in `config.env` at the root of the repository. To change models or update deployment settings, edit `config.env` - all other files will automatically use these values.

The `config.env` file contains:
- `MODEL_NAME`: Hugging Face model identifier (e.g., `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B`)
- `HF_CACHE_DIR`: Normalized cache directory name (e.g., `models--deepseek-ai--DeepSeek-R1-Distill-Qwen-1.5B`)
- `SERVICE_NAME`: Cloud Run service name
- `ARTIFACT_REGISTRY_REPO`: Artifact Registry repository name
- `ARTIFACT_REGISTRY_IMAGE`: Container image name

This configuration is loaded by:
- Dockerfile (during build to download the correct model)
- entrypoint.sh (at runtime to configure the server)
- prewarm_compile.py (for pre-warming requests)

## Architecture

The project consists of six main components:

1. **Dockerfile**: Builds a container based on `nvcr.io/nvidia/vllm:25.10-py3` (NVIDIA NGC) that:
   - Downloads the `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B` model during build time using a Hugging Face token
   - Configures the runtime environment to run offline (no Hugging Face Hub access)
   - Sets up custom entrypoint for pre-warming when torch.compile is enabled
   - Installs FastAPI and dependencies for API gateway
   - Serves the model via OpenAI-compatible API with API key authentication

2. **API Gateway** (`api_gateway.py`):
   - FastAPI application that provides API key authentication
   - Loads valid API keys from Google Secret Manager on startup
   - Validates `X-API-Key` header on all requests (except `/health`)
   - Proxies authenticated requests to vLLM server on internal port 8080
   - Returns 401 Unauthorized for invalid or missing API keys
   - Provides `/admin/reload-keys` endpoint to refresh keys without restarting

3. **Runtime Entrypoint** (`entrypoint.sh` + `prewarm_compile.py`):
   - `entrypoint.sh`: Custom startup script with comprehensive timing instrumentation
   - Starts vLLM server in background on port 8080 (internal only)
   - Conditionally runs pre-warming if `VLLM_TORCH_COMPILE_LEVEL > 0`
   - Starts API gateway in foreground on port 8000 (exposed to Cloud Run)
   - `prewarm_compile.py`: Makes test requests with various input lengths (128, 256, 512, 1024, 2048 tokens) to populate torch.compile cache
   - Manages lifecycle of both services

4. **Cloud Build Pipeline** (`cloudbuild.yaml`): Multi-step CI/CD pipeline with:
   - **Build step**: Uses Docker buildx with `E2_HIGHCPU_8` machine, securely injects `HF_TOKEN` from Secret Manager
   - **Deploy step**: Automatically deploys to Cloud Run (`vllm-deepseek-r1-1-5b` service) with GPU configuration (8 CPU, 32Gi memory, 1x nvidia-l4)
   - Sets environment variables for Secret Manager integration (`GCP_PROJECT`, `API_KEYS_SECRET_NAME`)
   - **Test step**: Installs dependencies and runs pytest tests against deployed service
   - Pushes to Google Artifact Registry at `us-central1-docker.pkg.dev/${PROJECT_ID}/vllm-deepseek-r1-repo/vllm-deepseek-r1-1-5b`

5. **Testing Infrastructure**:
   - `test_endpoint.py`: Pytest-based tests that verify `/v1/models` and `/v1/completions` endpoints
   - `test_endpoint.sh`: Bash-based health check script (alternative to pytest)
   - Tests retrieve Cloud Run service URL dynamically and verify model responsiveness
   - `requirements-test.txt`: Test dependencies (pytest, requests)

6. **Build Notification Handler** (`build-notification-handler/main.py`):
   - Cloud Function that responds to Cloud Build Pub/Sub notifications
   - Fetches logs for failed builds from Cloud Logging
   - Prepared for integration with Gemini API for automated failure analysis (commented out)

7. **API Key Management** ([databitings-api-key-manager](https://github.com/patelmm79/databitings-api-key-manager)):
   - Separate CLI tool repository for managing API keys in Google Secret Manager
   - Generates secure random API keys with `sk-` prefix
   - Supports adding, listing, removing, and rotating keys
   - Keys stored as JSON in Secret Manager for easy management
   - Reusable across multiple projects and services

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

Configuration is centralized in `config.env`. The following environment variables are used:

- `MODEL_NAME`: Hugging Face model identifier (set in `config.env`)
- `HF_CACHE_DIR`: Normalized cache directory name (set in `config.env`)
- `MODEL_REPO`: The model repository identifier (derived from `MODEL_NAME`)
- `MODEL_PATH`: The actual filesystem path to the cached model (resolved at runtime)
- `HF_HOME`: Model cache directory (`/model-cache`)
- `HF_TOKEN`: Required for downloading the model from Hugging Face (Secret Manager)
- `HF_HUB_OFFLINE`: Set to `1` in final container to prevent runtime Hub access
- `PORT`: Server port (defaults to 8080 on Cloud Run, 8000 locally)
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

**API Gateway Environment Variables:**
- `GCP_PROJECT`: Google Cloud project ID (automatically set by Cloud Run deployment)
- `API_KEYS_SECRET_NAME`: Name of the Secret Manager secret containing API keys (default: `vllm-api-keys`)
- `VLLM_BASE_URL`: Internal URL of vLLM server (default: `http://localhost:8080`)

## Runtime Configuration

The container serves the model via vLLM's OpenAI-compatible API with these defaults:
- Port: 8000 (configurable via `PORT` env var)
- Model: `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B` (1.5B parameters)
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

## API Key Setup and Management

The service uses API key authentication to protect access. API keys are stored in Google Secret Manager and validated by the FastAPI gateway.

### Initial Setup

**1. Install the API key manager tool:**

API keys are managed using the separate [databitings-api-key-manager](https://github.com/patelmm79/databitings-api-key-manager) repository.

```bash
# Clone the repository
git clone https://github.com/patelmm79/databitings-api-key-manager.git
cd databitings-api-key-manager

# Install dependencies
pip install -r requirements.txt

# Set your GCP project ID
export PROJECT_ID="your-project-id"

# Create the secret
python manage_api_keys.py create-secret --project $PROJECT_ID --secret vllm-api-keys
```

**2. Grant Cloud Run service account access to Secret Manager:**

```bash
# Get your Cloud Run service account (format: PROJECT_NUMBER-compute@developer.gserviceaccount.com)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Grant Secret Manager access
gcloud secrets add-iam-policy-binding vllm-api-keys \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"
```

**3. Generate your first API key:**

```bash
python manage_api_keys.py add-key --project $PROJECT_ID --secret vllm-api-keys --name "my-local-service"
```

This will output a new API key like `sk-abc123...`. **Save this key securely** - it won't be shown again!

### Managing API Keys

For complete documentation on managing API keys, see the [databitings-api-key-manager README](https://github.com/patelmm79/databitings-api-key-manager#readme).

**List all API keys (names only):**
```bash
python manage_api_keys.py list-keys --project $PROJECT_ID --secret vllm-api-keys
```

**Add a new API key:**
```bash
python manage_api_keys.py add-key --project $PROJECT_ID --secret vllm-api-keys --name "production-app"
```

**Remove an API key:**
```bash
python manage_api_keys.py remove-key --project $PROJECT_ID --secret vllm-api-keys --name "old-service"
```

**Rotate a key (generate new key for existing name):**
```bash
python manage_api_keys.py rotate-key --project $PROJECT_ID --secret vllm-api-keys --name "my-local-service"
```

### Using API Keys

Include the API key in the `X-API-Key` header with all requests:

**Example with curl:**
```bash
SERVICE_URL=$(gcloud run services describe vllm-deepseek-r1-1-5b --region us-central1 --format='value(status.url)')

curl -X POST "${SERVICE_URL}/v1/completions" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: sk-your-api-key-here" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
    "prompt": "Once upon a time",
    "max_tokens": 50
  }'
```

**Example with Python:**
```python
import requests

SERVICE_URL = "https://your-service-url.run.app"
API_KEY = "sk-your-api-key-here"

response = requests.post(
    f"{SERVICE_URL}/v1/completions",
    headers={
        "Content-Type": "application/json",
        "X-API-Key": API_KEY
    },
    json={
        "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
        "prompt": "Once upon a time",
        "max_tokens": 50
    }
)

print(response.json())
```

### Key Rotation Without Downtime

You can rotate keys without restarting the container:

1. Add a new key with the same name (or create a new one)
2. Update your clients to use the new key
3. Call the `/admin/reload-keys` endpoint (requires valid API key):

```bash
curl -X GET "${SERVICE_URL}/admin/reload-keys" \
  -H "X-API-Key: sk-your-api-key-here"
```

4. Once all clients are updated, remove the old key from Secret Manager

### Security Notes

- API keys are stored securely in Google Secret Manager with encryption at rest
- Keys are loaded into memory on container startup and never logged
- The `/health` endpoint does not require authentication (used for Cloud Run health checks)
- All other endpoints require a valid API key
- Invalid API key attempts are logged for audit purposes

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

## Changing Models

To switch to a different model, follow these steps:

1. **Edit `config.env`** and update the following variables:
   ```bash
   # Example: Switching to Llama 3.2 1B
   MODEL_NAME=meta-llama/Llama-3.2-1B

   # Update HF_CACHE_DIR (replace "/" with "--", add "models--" prefix)
   HF_CACHE_DIR=models--meta-llama--Llama-3.2-1B

   # Optionally update service names
   SERVICE_NAME=vllm-llama-3-2-1b
   ARTIFACT_REGISTRY_REPO=vllm-llama-repo
   ARTIFACT_REGISTRY_IMAGE=vllm-llama-3-2-1b
   ```

2. **Ensure your HF_TOKEN has access** to the new model on Hugging Face Hub

3. **Create Artifact Registry repository** (if you changed the repo name):
   ```bash
   gcloud artifacts repositories create vllm-llama-repo \
     --repository-format=docker \
     --location=us-central1
   ```

4. **Update `cloudbuild.yaml`** substitutions section (if you changed artifact registry names):
   ```yaml
   substitutions:
     _IMAGE: 'us-central1-docker.pkg.dev/${PROJECT_ID}/vllm-llama-repo/vllm-llama-3-2-1b'
   ```

5. **Rebuild and deploy**:
   ```bash
   gcloud builds submit --config cloudbuild.yaml
   ```

That's it! All scripts and configuration will automatically use the values from `config.env`.

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
- Verify `HF_TOKEN` has access to `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B` model
- Check build logs for download errors
- Ensure sufficient disk space in build environment (model is ~3GB in BF16)

**Tests failing?**
- Verify Cloud Run service name matches `SERVICE_NAME` in `test_endpoint.py` (should be `vllm-deepseek-r1-1-5b`)
- Check that service is deployed and healthy before running tests
- Review Cloud Run logs for server errors