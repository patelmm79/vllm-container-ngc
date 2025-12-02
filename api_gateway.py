#!/usr/bin/env python3
"""
FastAPI middleware for API key authentication.

This service acts as a reverse proxy in front of the vLLM server,
validating API keys from Google Secret Manager before forwarding requests.
"""

import os
import json
import logging
from typing import Optional, Set
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Request, Depends
from fastapi.responses import StreamingResponse, Response
import httpx
from google.cloud import secretmanager

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

# Global variable to store valid API keys
valid_api_keys: Set[str] = set()


def load_api_keys_from_secret_manager() -> Set[str]:
    """
    Load API keys from Google Secret Manager.

    Expected secret format (JSON):
    {
        "service-a": "sk-abc123...",
        "service-b": "sk-def456...",
        "local-dev": "sk-ghi789..."
    }

    Returns:
        Set of valid API key strings
    """
    try:
        if not GCP_PROJECT:
            logger.warning("GCP_PROJECT not set, API key validation will fail")
            return set()

        client = secretmanager.SecretManagerServiceClient()
        secret_path = f"projects/{GCP_PROJECT}/secrets/{SECRET_NAME}/versions/latest"

        logger.info(f"Loading API keys from Secret Manager: {secret_path}")
        response = client.access_secret_version(request={"name": secret_path})

        secret_data = response.payload.data.decode("UTF-8")
        keys_dict = json.loads(secret_data)

        # Extract all key values (not the names)
        keys = set(keys_dict.values())
        logger.info(f"Loaded {len(keys)} valid API keys from Secret Manager")

        return keys

    except Exception as e:
        logger.error(f"Failed to load API keys from Secret Manager: {e}")
        raise


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load API keys on startup."""
    global valid_api_keys

    logger.info("Starting API Gateway...")
    valid_api_keys = load_api_keys_from_secret_manager()

    if not valid_api_keys:
        logger.error("No valid API keys loaded! Authentication will fail for all requests.")

    yield

    logger.info("Shutting down API Gateway...")


# Initialize FastAPI app
app = FastAPI(
    title="vLLM API Gateway",
    description="API key authentication layer for vLLM inference server",
    version="1.0.0",
    lifespan=lifespan
)


async def validate_api_key(x_api_key: Optional[str] = Header(None, alias="X-API-Key")) -> str:
    """
    Dependency to validate API key from request header.

    Accepts API key in header: X-API-Key: sk-your-key-here

    Args:
        x_api_key: API key from X-API-Key header

    Returns:
        The validated API key

    Raises:
        HTTPException: 401 if API key is invalid or missing
    """
    if not x_api_key:
        logger.warning("Request missing X-API-Key header")
        raise HTTPException(
            status_code=401,
            detail="Missing API key. Include X-API-Key header in your request."
        )

    if x_api_key not in valid_api_keys:
        logger.warning(f"Invalid API key attempted: {x_api_key[:10]}...")
        raise HTTPException(
            status_code=401,
            detail="Invalid API key"
        )

    return x_api_key


@app.get("/health")
async def health_check():
    """Health check endpoint (no authentication required)."""
    return {
        "status": "healthy",
        "service": "vllm-api-gateway",
        "keys_loaded": len(valid_api_keys)
    }


@app.get("/admin/reload-keys")
async def reload_keys(x_api_key: str = Depends(validate_api_key)):
    """
    Reload API keys from Secret Manager.
    Requires valid API key for authentication.
    """
    global valid_api_keys

    try:
        valid_api_keys = load_api_keys_from_secret_manager()
        logger.info("API keys reloaded successfully")
        return {
            "status": "success",
            "keys_loaded": len(valid_api_keys),
            "message": "API keys reloaded from Secret Manager"
        }
    except Exception as e:
        logger.error(f"Failed to reload API keys: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to reload keys: {str(e)}")


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy_to_vllm(
    request: Request,
    path: str,
    api_key: str = Depends(validate_api_key)
):
    """
    Proxy all authenticated requests to the vLLM server.

    Args:
        request: FastAPI request object
        path: Request path to forward
        api_key: Validated API key (from dependency)

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
