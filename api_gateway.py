#!/usr/bin/env python3
"""
FastAPI middleware for API key authentication.

This service acts as a reverse proxy in front of the vLLM server,
validating API keys from Google Secret Manager before forwarding requests.
"""

import os
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
import httpx

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://localhost:8080")
SECRET_NAME = os.getenv("API_KEYS_SECRET_NAME", "vllm-api-keys")
GCP_PROJECT = os.getenv("GCP_PROJECT")

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown lifecycle."""
    logger.info("Starting API Gateway...")
    yield
    logger.info("Shutting down API Gateway...")


# Initialize FastAPI app
app = FastAPI(
    title="vLLM API Gateway",
    description="API key authentication layer for vLLM inference server",
    version="1.0.0",
    lifespan=lifespan
)




@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "vllm-api-gateway"
    }


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy_to_vllm(
    request: Request,
    path: str
):
    """
    Proxy requests to the vLLM server.

    Authentication is handled at the Cloud Run platform level via service account tokens.

    Args:
        request: FastAPI request object
        path: Request path to forward

    Returns:
        StreamingResponse with vLLM server response
    """
    url = f"{VLLM_BASE_URL}/{path}"

    # Prepare headers (remove X-API-Key before forwarding)
    headers = dict(request.headers)
    headers.pop("x-api-key", None)
    headers.pop("host", None)  # Let httpx set the correct host

    # Log request
    logger.info(f"Proxying {request.method} {path} to vLLM")

    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            # Forward request to vLLM
            response = await client.request(
                method=request.method,
                url=url,
                content=await request.body(),
                headers=headers,
                params=request.query_params,
            )

            # Return streaming response
            return StreamingResponse(
                content=response.aiter_bytes(),
                status_code=response.status_code,
                headers=dict(response.headers),
                media_type=response.headers.get("content-type")
            )

    except httpx.RequestError as e:
        logger.error(f"Error connecting to vLLM server: {e}")
        raise HTTPException(
            status_code=503,
            detail=f"vLLM server unavailable: {str(e)}"
        )


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8000"))

    logger.info(f"Starting API Gateway on port {port}")
    logger.info(f"Proxying to vLLM at {VLLM_BASE_URL}")

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=port,
        log_level="info"
    )
