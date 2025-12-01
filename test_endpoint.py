
import os
import requests
import time
import subprocess
import pytest

# Load configuration from config.env
def load_config():
    """Load configuration from config.env file."""
    config = {}
    config_path = os.path.join(os.path.dirname(__file__), 'config.env')
    if os.path.exists(config_path):
        with open(config_path, 'r') as f:
            for line in f:
                line = line.strip()
                # Skip comments and empty lines
                if line and not line.startswith('#'):
                    if '=' in line:
                        key, value = line.split('=', 1)
                        config[key.strip()] = value.strip()
    return config

config = load_config()
SERVICE_NAME = config.get('SERVICE_NAME', 'vllm-deepseek-r1-1-5b')
MODEL_NAME = config.get('MODEL_NAME', 'deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B')
# Extract just the model name (last part after /)
MODEL_ID = MODEL_NAME.split('/')[-1] if '/' in MODEL_NAME else MODEL_NAME
REGION = "us-central1"

@pytest.fixture(scope="module")
def service_url():
    """
    Retrieves the Cloud Run service URL.
    First checks SERVICE_URL environment variable, then falls back to gcloud.
    """
    # Check for environment variable first
    env_url = os.environ.get('SERVICE_URL')
    if env_url:
        print(f"Using SERVICE_URL from environment: {env_url}")
        return env_url

    # Fall back to gcloud
    try:
        command = [
            "gcloud", "run", "services", "describe",
            SERVICE_NAME,
            "--platform", "managed",
            "--region", REGION,
            "--format", "value(status.url)"
        ]
        process = subprocess.run(command, capture_output=True, text=True, check=True)
        url = process.stdout.strip()
        if not url:
            pytest.fail("Failed to retrieve Cloud Run service URL.")
        return url
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        pytest.fail(f"Error retrieving service URL: {e}. "
                   f"Install gcloud CLI or set SERVICE_URL environment variable.")

@pytest.fixture(scope="module")
def auth_token():
    """
    Get authentication token for Cloud Run.
    First checks AUTH_TOKEN environment variable, then falls back to gcloud.
    """
    # Check for environment variable first
    env_token = os.environ.get('AUTH_TOKEN')
    if env_token:
        print(f"Using AUTH_TOKEN from environment")
        return env_token

    # Fall back to gcloud
    try:
        command = ["gcloud", "auth", "print-identity-token"]
        process = subprocess.run(command, capture_output=True, text=True, check=True)
        token = process.stdout.strip()
        if not token:
            pytest.fail("Failed to retrieve authentication token.")
        return token
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        pytest.fail(f"Error retrieving auth token: {e}. "
                   f"Install gcloud CLI or set AUTH_TOKEN environment variable.")

def test_models_endpoint(service_url, auth_token):
    """
    Tests the /v1/models endpoint.
    """
    endpoint_url = f"{service_url}/v1/models"
    headers = {"Authorization": f"Bearer {auth_token}"}
    print(f"Pinging model endpoint: {endpoint_url}")

    for i in range(5):
        try:
            response = requests.get(endpoint_url, headers=headers, timeout=30)
            print(f"Attempt {i+1}: Received HTTP status: {response.status_code}")
            if response.status_code == 200:
                break
        except requests.exceptions.RequestException as e:
            print(f"Attempt {i+1}: Request failed: {e}")
        time.sleep(10)
    else:
        pytest.fail("Health check failed after multiple attempts.")

    assert response.status_code == 200, "Endpoint did not return status 200."

    response_body = response.json()
    print(f"Response body: {response_body}")
    assert "data" in response_body, "Response body does not contain 'data' key."
    model_ids = [model["id"] for model in response_body["data"]]
    assert MODEL_ID in model_ids, f"Model '{MODEL_ID}' not found in response."

def test_completions_endpoint(service_url, auth_token):
    """
    Tests the /v1/completions endpoint.
    """
    completions_url = f"{service_url}/v1/completions"
    headers = {"Authorization": f"Bearer {auth_token}"}
    print(f"Testing completions endpoint: {completions_url}")

    payload = {
        "model": MODEL_ID,
        "prompt": "What is the capital of France?",
        "max_tokens": 50,
        "temperature": 0.7
    }

    response = requests.post(completions_url, json=payload, headers=headers, timeout=60)
    print(f"Completions response: {response.text}")

    assert response.status_code == 200, "Completions endpoint returned non-200 status."

    response_json = response.json()
    assert "choices" in response_json, "'choices' key not found in completions response."
    assert len(response_json["choices"]) > 0, "'choices' array is empty."
    assert "text" in response_json["choices"][0], "'text' key not found in the first choice."
    assert len(response_json["choices"][0]["text"]) > 0, "Generated text is empty."

