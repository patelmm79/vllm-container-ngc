#!/bin/bash
# entrypoint.sh - Startup script for vLLM container with API gateway and torch.compile pre-warming
#
# This script:
# 1. Starts the vLLM server in the background on port 8080
# 2. Runs the pre-warming script to trigger torch.compile for common input shapes
# 3. Starts the FastAPI API gateway in the foreground on port 8000 (with API key auth)
# 4. API gateway proxies authenticated requests to vLLM server

set -e  # Exit on error

# ============================================================================
# TIMING INSTRUMENTATION - Cold Start Profiling
# ============================================================================
# Record start time for overall cold start measurement (in milliseconds)
COLD_START_BEGIN=$(date +%s%3N)
STAGE_START=$COLD_START_BEGIN

# Function to log timing for each stage
log_timing() {
    local stage_name="$1"
    local current_time=$(date +%s%3N)  # milliseconds
    local stage_duration=$(( (current_time - STAGE_START) ))
    local total_elapsed=$(( (current_time - COLD_START_BEGIN) ))
    # Convert milliseconds to seconds with 2 decimal places
    printf "[TIMING] %-40s %8.2fs (total: %8.2fs)\n" "$stage_name" "$(awk "BEGIN {printf \"%.2f\", $stage_duration/1000}")" "$(awk "BEGIN {printf \"%.2f\", $total_elapsed/1000}")"
    STAGE_START=$current_time
}

echo "========================================="
echo "vLLM Container with API Gateway"
echo "========================================="
log_timing "Container initialization"

# Apply system configurations
echo "[Startup] Setting file descriptor limit..."
ulimit -n 1048576 2>/dev/null || echo "[Startup] Warning: Could not set ulimit (not permitted in this environment)"

echo "[Startup] Adding hostname to /etc/hosts..."
echo "127.0.0.1 $(hostname)" >> /etc/hosts 2>/dev/null || echo "[Startup] Warning: Could not modify /etc/hosts"
log_timing "System configuration"

# Source centralized configuration
echo "[Startup] Loading configuration from /app/config.env..."
if [ -f /app/config.env ]; then
    # Export all non-comment, non-empty lines from config.env
    export $(grep -v '^#' /app/config.env | grep -v '^$' | xargs)
    echo "[Startup] Configuration loaded successfully"
else
    echo "[Startup] Warning: /app/config.env not found, using defaults"
fi

# Export environment variables that should be inherited by child processes
# Use existing TORCH_CUDA_ARCH_LIST if set, otherwise default to 7.5 for T4 GPUs
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-7.5}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"

# Set MODEL_REPO from config.env or use default
export MODEL_REPO="${MODEL_NAME:-deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"

# Set HF_CACHE_DIR from config.env or derive from MODEL_REPO
export HF_CACHE_DIR="${HF_CACHE_DIR:-models--deepseek-ai--DeepSeek-R1-Distill-Qwen-1.5B}"

# Find the snapshot directory in the HF cache
if [ -d "${HF_HOME}/${HF_CACHE_DIR}" ]; then
    # Get the actual snapshot path (there should be only one)
    SNAPSHOT_DIR=$(find ${HF_HOME}/${HF_CACHE_DIR}/snapshots -maxdepth 1 -type d | tail -n 1)
    if [ -n "$SNAPSHOT_DIR" ]; then
        export MODEL_PATH="$SNAPSHOT_DIR"
        echo "[Startup] Using cached model at: $MODEL_PATH"
    else
        export MODEL_PATH="${MODEL_REPO}"
        echo "[Startup] Warning: Could not find snapshot directory, using repo name: $MODEL_PATH"
    fi
else
    export MODEL_PATH="${MODEL_REPO}"
    echo "[Startup] Warning: Model cache not found, using repo name: $MODEL_PATH"
fi

# Configure ports
# Cloud Run sets PORT env var (defaults to 8080), which will be used by the API gateway
# vLLM server runs on internal port 8080, API gateway exposes on $PORT
export GATEWAY_PORT="${PORT:-8000}"
export VLLM_PORT="8080"
export VLLM_BASE_URL="http://localhost:${VLLM_PORT}"

echo "[Startup] Configuration:"
echo "  MODEL_REPO: $MODEL_REPO"
echo "  MODEL_PATH: $MODEL_PATH"
echo "  GATEWAY_PORT: $GATEWAY_PORT (API gateway with auth)"
echo "  VLLM_PORT: $VLLM_PORT (internal vLLM server)"
echo "  TORCH_CUDA_ARCH_LIST: $TORCH_CUDA_ARCH_LIST"
echo "  HF_HUB_OFFLINE: $HF_HUB_OFFLINE"
echo "  VLLM_TORCH_COMPILE_LEVEL: ${VLLM_TORCH_COMPILE_LEVEL:-1}"
echo "  GCP_PROJECT: ${GCP_PROJECT:-not set}"
echo "  API_KEYS_SECRET_NAME: ${API_KEYS_SECRET_NAME:-vllm-api-keys}"
log_timing "Environment setup"

# Start vLLM server in the background on internal port
echo ""
echo "[Startup] Starting vLLM server on internal port ${VLLM_PORT}..."
python3 -m vllm.entrypoints.openai.api_server \
    --port ${VLLM_PORT} \
    --model ${MODEL_PATH} \
    --gpu-memory-utilization 0.95 \
    --dtype float16 \
    --max-num-seqs 8 \
    --disable-log-stats \
    ${MAX_MODEL_LEN:+--max-model-len "$MAX_MODEL_LEN"} \
    &

# Store the PID of the vLLM server
VLLM_PID=$!
echo "[Startup] vLLM server started with PID: $VLLM_PID"
log_timing "vLLM server startup (background)"

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "[Startup] Received shutdown signal, stopping services..."
    if [ -n "$GATEWAY_PID" ]; then
        echo "[Startup] Stopping API gateway (PID: $GATEWAY_PID)..."
        kill -TERM "$GATEWAY_PID" 2>/dev/null || true
    fi
    if [ -n "$VLLM_PID" ]; then
        echo "[Startup] Stopping vLLM server (PID: $VLLM_PID)..."
        kill -TERM "$VLLM_PID" 2>/dev/null || true
    fi
    wait "$VLLM_PID" 2>/dev/null || true
    wait "$GATEWAY_PID" 2>/dev/null || true
    exit 0
}

# Register cleanup function for common termination signals
trap cleanup SIGTERM SIGINT SIGQUIT

# Run pre-warming script
# This script will wait for the server to be ready, then make test requests
# to trigger torch.compile for common input shapes
echo ""
echo "[Startup] Running pre-warming script..."
if ! python3 /app/prewarm_compile.py; then
    echo "[Startup] WARNING: Pre-warming script failed or was skipped"
    echo "[Startup] Continuing with server startup anyway..."
fi
log_timing "Pre-warming script execution"

# Check if vLLM server is still running
if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo "[Startup] ERROR: vLLM server has stopped unexpectedly!"
    exit 1
fi

# Pre-warming complete, now start API gateway in foreground
echo ""
echo "[Startup] Pre-warming complete! Starting API gateway..."
log_timing "Pre-warming complete"

# Start FastAPI API gateway in foreground
# This will authenticate requests and proxy them to the vLLM server
echo "[Startup] Starting API gateway on port ${GATEWAY_PORT}..."

# Export environment variables for the API gateway
export PORT="${GATEWAY_PORT}"
export VLLM_BASE_URL="${VLLM_BASE_URL}"
export GCP_PROJECT="${GCP_PROJECT}"
export API_KEYS_SECRET_NAME="${API_KEYS_SECRET_NAME:-vllm-api-keys}"

python3 /app/api_gateway.py &
GATEWAY_PID=$!
echo "[Startup] API gateway started with PID: $GATEWAY_PID"
log_timing "API gateway startup"

# Print final summary
echo ""
echo "========================================="
echo "COLD START TIMING SUMMARY"
echo "========================================="
TOTAL_COLD_START=$(( $(date +%s%3N) - COLD_START_BEGIN ))
printf "Total cold start time: %.2f seconds\n" "$(awk "BEGIN {printf \"%.2f\", $TOTAL_COLD_START/1000}")"
echo "========================================="
echo ""
echo "[Startup] Container is ready!"
echo "  - API Gateway: http://0.0.0.0:${GATEWAY_PORT} (requires X-API-Key header)"
echo "  - vLLM Server: http://localhost:${VLLM_PORT} (internal only)"
echo "========================================="

# Wait for either process to complete
# This keeps the container running and passes signals to both services
wait -n "$VLLM_PID" "$GATEWAY_PID"

# If we get here, one of the processes has exited
echo "[Startup] ERROR: A service has exited unexpectedly!"
exit 1
