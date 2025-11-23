#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

SERVICE_NAME="vllm-deepseek-r1-1-5b"
REGION="us-central1"

echo "--- Starting Post-Deployment Test ---"

# Get the URL of the deployed Cloud Run service
echo "Fetching URL for service: $SERVICE_NAME"
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --platform managed --region $REGION --format 'value(status.url)')

if [ -z "$SERVICE_URL" ]; then
    echo "Error: Could not retrieve service URL for $SERVICE_NAME."
    exit 1
fi

echo "Service URL: $SERVICE_URL"
ENDPOINT_URL="$SERVICE_URL/v1/models"

echo "Pinging model endpoint: $ENDPOINT_URL"

# Use curl to send a request to the /v1/models endpoint
# We'll retry a few times to give the new revision time to become responsive.
for i in {1..5}; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 30 "$ENDPOINT_URL")
    echo "Attempt $i: Received HTTP status: $HTTP_STATUS"
    if [ "$HTTP_STATUS" -eq 200 ]; then
        break
    fi
    sleep 10
done

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Error: Health check failed after multiple attempts. Endpoint returned status $HTTP_STATUS."
    exit 1
else
    echo "Success: Endpoint returned status 200."
    RESPONSE_BODY=$(curl -s "$ENDPOINT_URL")
    echo "Response body: $RESPONSE_BODY"
    if [[ "$RESPONSE_BODY" != *"DeepSeek-R1-Distill-Qwen-1.5B"* ]]; then
        echo "Error: Model name 'DeepSeek-R1-Distill-Qwen-1.5B' not found in response."
        exit 1
    fi
    echo "Success: Model name found in response body."
fi

# Test the completions endpoint
COMPLETIONS_URL="$SERVICE_URL/v1/completions"
echo "Testing completions endpoint: $COMPLETIONS_URL"

read -r -d '' PAYLOAD << EOM
{
  "model": "DeepSeek-R1-Distill-Qwen-1.5B",
  "prompt": "What is the capital of France?",
  "max_tokens": 50,
  "temperature": 0.7
}
EOM

COMPLETIONS_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$COMPLETIONS_URL")

echo "Completions response: $COMPLETIONS_RESPONSE"

if [[ -z "$COMPLETIONS_RESPONSE" ]]; then
    echo "Error: Empty response from completions endpoint."
    exit 1
fi

# Check for the presence of 'choices' array in the response using jq
if ! echo "$COMPLETIONS_RESPONSE" | jq -e '.choices' > /dev/null; then
    echo "Error: 'choices' key not found in completions response."
    exit 1
fi

echo "Success: Completions endpoint returned a valid response."


echo "--- Post-Deployment Test Passed ---"
exit 0
