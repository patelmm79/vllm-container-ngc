#!/bin/bash
# entrypoint.sh - Startup script for vLLM container with torch.compile pre-warming
#
# This script:
# 1. Starts the vLLM server in the background
# 2. Runs the pre-warming script to trigger torch.compile for common input shapes
# 3. Brings the vLLM server to the foreground for normal operation

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
echo "vLLM Container Startup with Pre-warming"
echo "========================================="
log_timing "Container initialization"

# Apply system configurations
echo "[Startup] Setting file descriptor limit..."
ulimit -n 1048576 2>/dev/null || echo "[Startup] Warning: Could not set ulimit (not permitted in this environment)"

echo "[Startup] Adding hostname to /etc/hosts..."
echo "127.0.0.1 $(hostname)" >> /etc/hosts 2>/dev/null || echo "[Startup] Warning: Could not modify /etc/hosts"
log_timing "System configuration"

# Export environment variables that should be inherited by child processes
# Use existing TORCH_CUDA_ARCH_LIST if set, otherwise default to 7.5 for T4 GPUs
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-7.5}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"

# Resolve the model path from the cache
# When offline, we need to point to the actual cached directory
export MODEL_REPO="${MODEL_REPO:-deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"

# Find the snapshot directory in the HF cache
if [ -d "${HF_HOME}/models--deepseek-ai--DeepSeek-R1-Distill-Qwen-1.5B" ]; then
    # Get the actual snapshot path (there should be only one)
    SNAPSHOT_DIR=$(find ${HF_HOME}/models--deepseek-ai--DeepSeek-R1-Distill-Qwen-1.5B/snapshots -maxdepth 1 -type d | tail -n 1)
    if [ -n "$SNAPSHOT_DIR" ]; then
        export MODEL_NAME="$SNAPSHOT_DIR"
        echo "[Startup] Using cached model at: $MODEL_NAME"
    else
        export MODEL_NAME="${MODEL_REPO}"
        echo "[Startup] Warning: Could not find snapshot directory, using repo name: $MODEL_NAME"
    fi
else
    export MODEL_NAME="${MODEL_REPO}"
    echo "[Startup] Warning: Model cache not found, using repo name: $MODEL_NAME"
fi

export PORT="${PORT:-8000}"

echo "[Startup] Configuration:"
echo "  MODEL_NAME: $MODEL_NAME"
echo "  PORT: $PORT"
echo "  TORCH_CUDA_ARCH_LIST: $TORCH_CUDA_ARCH_LIST"
echo "  HF_HUB_OFFLINE: $HF_HUB_OFFLINE"
echo "  VLLM_TORCH_COMPILE_LEVEL: ${VLLM_TORCH_COMPILE_LEVEL:-1}"
log_timing "Environment setup"

# Start vLLM server in the background
echo ""
echo "[Startup] Starting vLLM server in background..."
python3 -m vllm.entrypoints.openai.api_server \
    --port ${PORT} \
    --model ${MODEL_NAME} \
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
    echo "[Startup] Received shutdown signal, stopping vLLM server..."
    kill -TERM "$VLLM_PID" 2>/dev/null || true
    wait "$VLLM_PID" 2>/dev/null || true
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

# Pre-warming complete, now keep the vLLM server running in foreground
echo ""
echo "[Startup] Pre-warming complete! Server is ready to accept requests."
echo "[Startup] vLLM server is now running on port $PORT"
echo "========================================="
log_timing "Ready to serve"

# Print final summary
echo ""
echo "========================================="
echo "COLD START TIMING SUMMARY"
echo "========================================="
TOTAL_COLD_START=$(( $(date +%s%3N) - COLD_START_BEGIN ))
printf "Total cold start time: %.2f seconds\n" "$(awk "BEGIN {printf \"%.2f\", $TOTAL_COLD_START/1000}")"
echo "========================================="
echo ""

# Wait for the vLLM server process to complete
# This keeps the container running and passes signals to the server
wait "$VLLM_PID"
