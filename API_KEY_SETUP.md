# API Key Authentication Setup Guide

This guide explains how to set up and use API key authentication for your vLLM Cloud Run service.

## Overview

Your vLLM service now includes a FastAPI API gateway that provides:
- **API key authentication** using Google Secret Manager
- **Secure key storage** with encryption at rest
- **Easy key management** via command-line tool
- **Zero-downtime key rotation**

## Architecture

```
Client Request
    ↓
    | (includes X-API-Key header)
    ↓
FastAPI API Gateway (Port 8000)
    ↓
    | (validates key against Secret Manager)
    ↓
vLLM Server (Port 8080, internal only)
    ↓
Response
```

## Quick Start

### Step 1: Install Dependencies

```bash
pip install -r requirements-management.txt
```

### Step 2: Set Up Secret Manager

```bash
# Set your project ID
export PROJECT_ID="your-gcp-project-id"

# Create the secret
python manage_api_keys.py create-secret --project $PROJECT_ID
```

### Step 3: Grant Permissions

```bash
# Get your Cloud Run service account
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Grant access to Secret Manager
gcloud secrets add-iam-policy-binding vllm-api-keys \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"
```

### Step 4: Generate First API Key

```bash
python manage_api_keys.py add-key --project $PROJECT_ID --name "local-dev"
```

**Save the output!** The API key will look like: `sk-abc123...`

### Step 5: Deploy Updated Service

```bash
gcloud builds submit --config cloudbuild.yaml
```

### Step 6: Test Authentication

```bash
# Get service URL
SERVICE_URL=$(gcloud run services describe vllm-deepseek-r1-1-5b \
  --region us-central1 \
  --format='value(status.url)')

# Test with API key
curl -X POST "${SERVICE_URL}/v1/completions" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: sk-your-key-here" \
  -d '{
    "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
    "prompt": "Hello, world!",
    "max_tokens": 20
  }'
```

## Managing API Keys

### List Keys
```bash
python manage_api_keys.py list-keys --project $PROJECT_ID
```

### Add a New Key
```bash
python manage_api_keys.py add-key --project $PROJECT_ID --name "production-service"
```

### Remove a Key
```bash
python manage_api_keys.py remove-key --project $PROJECT_ID --name "old-service"
```

### Rotate a Key
```bash
python manage_api_keys.py rotate-key --project $PROJECT_ID --name "local-dev"
```

## Using API Keys in Your Applications

### Python Example

```python
import requests

SERVICE_URL = "https://your-service-url.run.app"
API_KEY = "sk-your-api-key-here"

def query_llm(prompt: str, max_tokens: int = 50):
    response = requests.post(
        f"{SERVICE_URL}/v1/completions",
        headers={
            "Content-Type": "application/json",
            "X-API-Key": API_KEY
        },
        json={
            "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
            "prompt": prompt,
            "max_tokens": max_tokens
        }
    )
    response.raise_for_status()
    return response.json()

# Use it
result = query_llm("What is the meaning of life?")
print(result["choices"][0]["text"])
```

### JavaScript/TypeScript Example

```typescript
const SERVICE_URL = "https://your-service-url.run.app";
const API_KEY = "sk-your-api-key-here";

async function queryLLM(prompt: string, maxTokens: number = 50) {
  const response = await fetch(`${SERVICE_URL}/v1/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": API_KEY,
    },
    body: JSON.stringify({
      model: "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
      prompt: prompt,
      max_tokens: maxTokens,
    }),
  });

  if (!response.ok) {
    throw new Error(`HTTP error! status: ${response.status}`);
  }

  return await response.json();
}

// Use it
const result = await queryLLM("What is the meaning of life?");
console.log(result.choices[0].text);
```

## Key Rotation Without Downtime

To rotate keys without service interruption:

1. **Generate a new key** for the same service:
   ```bash
   python manage_api_keys.py rotate-key --project $PROJECT_ID --name "production-service"
   ```

2. **Update your client applications** to use the new key

3. **Reload keys** in the running container (no restart needed):
   ```bash
   curl -X GET "${SERVICE_URL}/admin/reload-keys" \
     -H "X-API-Key: sk-your-new-key-here"
   ```

4. **Verify** old key no longer works:
   ```bash
   curl -X POST "${SERVICE_URL}/v1/completions" \
     -H "X-API-Key: sk-old-key-here" \
     -d '{"model": "...", "prompt": "test"}'
   # Should return 401 Unauthorized
   ```

## Troubleshooting

### "Invalid API key" Error

- Verify your API key is correct (check for typos)
- Ensure the key exists: `python manage_api_keys.py list-keys --project $PROJECT_ID`
- Check you're using the `X-API-Key` header (not `Authorization`)

### "Missing API key" Error

- Make sure you include the `X-API-Key` header in your request
- Header name is case-sensitive

### Container Can't Access Secret Manager

- Verify IAM permissions: `gcloud secrets get-iam-policy vllm-api-keys`
- Ensure Cloud Run service account has `secretmanager.secretAccessor` role
- Check GCP_PROJECT environment variable is set in Cloud Run deployment

### Keys Not Updating

- Try calling `/admin/reload-keys` endpoint to refresh keys without restart
- Verify latest secret version exists in Secret Manager
- Check container logs for Secret Manager access errors

## Security Best Practices

1. **Store keys securely**: Never commit API keys to version control
2. **Use environment variables**: Store keys in `.env` files (gitignored) for local development
3. **Rotate regularly**: Rotate keys every 90 days or when team members leave
4. **Monitor usage**: Check Cloud Run logs for unauthorized access attempts
5. **Limit key scope**: Create separate keys for each service/environment
6. **Use descriptive names**: Name keys after their purpose (e.g., "production-web-app", "staging-api")

## Cost Considerations

- **Secret Manager**: First 6 secret versions are free, then $0.06/version/month
- **Secret Access**: First 10,000 operations/month free, then $0.03/10,000 operations
- For typical usage (few keys, occasional access), costs are negligible (< $1/month)

## Next Steps

- Set up monitoring for failed authentication attempts
- Create separate keys for each environment (dev, staging, production)
- Document which services use which keys
- Set up alerts for Secret Manager access patterns

## Support

For issues or questions:
- Check Cloud Run logs: `gcloud run services logs read vllm-deepseek-r1-1-5b --region us-central1`
- Review container startup logs for Secret Manager errors
- Verify Secret Manager permissions and configuration
