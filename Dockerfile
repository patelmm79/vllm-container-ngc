FROM vllm/vllm-openai:latest

# Accept TORCH_CUDA_ARCH_LIST as a build argument (defaults to 7.5 for T4 GPUs)
ARG TORCH_CUDA_ARCH_LIST=7.5

# Set CUDA architecture FIRST, before any other operations
# This must be set early to prevent PyTorch from compiling for all visible architectures
# NVIDIA T4 (used in Google Cloud Run) has compute capability 7.5
# This reduces compilation time significantly by targeting only the specific architecture
ENV TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST}"

ENV HF_HOME=/model-cache

ENV HF_HUB_OFFLINE=1

# Suppress PyTorch distributed communication (c10d) warnings
# This prevents the "destroy_process_group() was not called" warning which is
# harmless in single-container inference setups where the OS reclaims resources on exit
ENV TORCH_DISTRIBUTED_DEBUG=OFF

# Disable torch.compile for faster cold starts in Cloud Run auto-scaling environments
#
# torch.compile adds ~60 seconds to cold start time but only caches for a single container instance.
# Since Cloud Run frequently creates new container instances during auto-scaling, each instance
# pays the 60s compilation cost, and the cache cannot persist across instances.
#
# Trade-offs of disabling (VLLM_TORCH_COMPILE_LEVEL=0):
#   ✓ ~60 seconds faster cold starts (149s → ~90s)
#   ✓ More predictable startup time
#   ✓ Better for frequent scaling events (bursty traffic)
#   ✗ ~10-30% lower throughput for individual requests
#   ✗ ~50-200ms higher per-request latency
#
# If you have sustained traffic and can keep containers warm with minInstances > 0,
# consider setting this to 1 to enable torch.compile for better per-request performance.
ENV VLLM_TORCH_COMPILE_LEVEL=0

# Disable OpenTelemetry SDK to prevent trace context warnings
# This suppresses "Received a request with trace context but tracing is disabled" warnings
# when the vLLM server receives requests with trace headers but doesn't have an OTLP exporter configured
ENV OTEL_SDK_DISABLED=true

# Install requests library for pre-warming script
RUN pip install --no-cache-dir requests

# Copy pre-warming script and startup script
COPY prewarm_compile.py /app/prewarm_compile.py
COPY entrypoint.sh /app/entrypoint.sh

# Make scripts executable
RUN chmod +x /app/prewarm_compile.py /app/entrypoint.sh

# Use custom entrypoint that handles pre-warming
# The entrypoint script will:
# 1. Start vLLM server in background
# 2. Run pre-warming to trigger torch.compile for common input shapes
# 3. Keep vLLM server running in foreground for normal operation
ENTRYPOINT ["/app/entrypoint.sh"]
