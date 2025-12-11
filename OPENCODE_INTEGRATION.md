# Connecting OpenCode.ai to vLLM Service

This guide explains how to connect [OpenCode.ai](https://opencode.ai) (an open-source AI coding agent) to your self-hosted vLLM inference service running on Google Cloud Run.

## Overview

OpenCode.ai supports custom LLM providers through OpenAI-compatible API configuration. Since this vLLM service provides an OpenAI-compatible API with API key authentication, you can easily integrate it with OpenCode as a custom provider.

## Prerequisites

1. **Deployed vLLM Service**: Your Cloud Run service must be deployed and running
2. **API Key**: You need a valid API key from Google Secret Manager (see [API Key Setup](#api-key-setup) below)
3. **OpenCode Installed**: Install OpenCode.ai from [opencode.ai](https://opencode.ai)

## Step 1: Get Your Service URL

Retrieve your Cloud Run service URL:

```bash
SERVICE_URL=$(gcloud run services describe vllm-deepseek-r1-1-5b \
  --region us-central1 \
  --format='value(status.url)')

echo "Service URL: $SERVICE_URL"
```

The URL will look like: `https://vllm-deepseek-r1-1-5b-XXXXXXXXXX-uc.a.run.app`

## Step 2: API Key Setup

If you haven't already created an API key, follow the [API Key Management](CLAUDE.md#api-key-setup-and-management) instructions.

**Quick setup:**

```bash
# Clone the API key manager tool
git clone https://github.com/patelmm79/databitings-api-key-manager.git
cd databitings-api-key-manager

# Install dependencies
pip install -r requirements.txt

# Set your project ID
export PROJECT_ID="your-project-id"

# Generate an API key for OpenCode
python manage_api_keys.py add-key \
  --project $PROJECT_ID \
  --secret vllm-api-keys \
  --name "opencode-integration"
```

**Save the generated API key** (format: `sk-abc123...`) - you'll need it for the next step.

## Step 3: Configure OpenCode

### Option A: Environment Variable (Recommended)

1. **Set your API key as an environment variable:**

```bash
# Linux/macOS
export VLLM_API_KEY="sk-your-api-key-here"

# Windows (PowerShell)
$env:VLLM_API_KEY="sk-your-api-key-here"

# Windows (Command Prompt)
set VLLM_API_KEY=sk-your-api-key-here
```

2. **Create or edit `opencode.json` in your project directory:**

```json
{
  "provider": {
    "vllm-deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM DeepSeek R1",
      "options": {
        "baseURL": "https://vllm-deepseek-r1-1-5b-XXXXXXXXXX-uc.a.run.app/v1",
        "apiKey": "{env:VLLM_API_KEY}",
        "headers": {
          "X-API-Key": "{env:VLLM_API_KEY}"
        }
      },
      "models": {
        "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B": {
          "name": "DeepSeek R1 Distill Qwen 1.5B",
          "limit": {
            "context": 32768,
            "output": 4096
          }
        }
      }
    }
  }
}
```

**Important**: Replace the `baseURL` with your actual Cloud Run service URL from Step 1.

### Option B: Direct API Key (Less Secure)

If you prefer to hardcode the API key (not recommended for shared codebases):

```json
{
  "provider": {
    "vllm-deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM DeepSeek R1",
      "options": {
        "baseURL": "https://vllm-deepseek-r1-1-5b-XXXXXXXXXX-uc.a.run.app/v1",
        "headers": {
          "X-API-Key": "sk-your-api-key-here"
        }
      },
      "models": {
        "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B": {
          "name": "DeepSeek R1 Distill Qwen 1.5B",
          "limit": {
            "context": 32768,
            "output": 4096
          }
        }
      }
    }
  }
}
```

## Step 4: Select Your Model in OpenCode

1. **Open OpenCode** (terminal, desktop app, or IDE extension)

2. **Run the models command:**
   ```
   /models
   ```

3. **Select your custom provider:**
   - Navigate to "vLLM DeepSeek R1" in the provider list
   - Select "DeepSeek R1 Distill Qwen 1.5B" as your model

4. **Start coding!** OpenCode will now use your self-hosted vLLM service for all AI interactions.

## Configuration Options Explained

### Provider Configuration

- **`npm`**: Package identifier for OpenAI-compatible providers (keep as `@ai-sdk/openai-compatible`)
- **`name`**: Display name shown in OpenCode's UI
- **`baseURL`**: Your Cloud Run service URL + `/v1` endpoint
- **`apiKey`**: (Optional) OpenAI-style API key for compatibility
- **`headers.X-API-Key`**: Your actual vLLM service API key (required for authentication)

### Model Configuration

- **Model ID**: Must match exactly: `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B`
- **`name`**: Display name shown in OpenCode's model selector
- **`limit.context`**: Maximum context window (32,768 tokens for this model)
- **`limit.output`**: Maximum output tokens (adjust based on your needs)

## Verifying the Connection

Test the connection with a simple prompt:

```
/chat What is the capital of France?
```

If configured correctly, you should receive a response from your vLLM service. Check the Cloud Run logs to confirm:

```bash
gcloud run services logs read vllm-deepseek-r1-1-5b \
  --region us-central1 \
  --limit 50
```

## Troubleshooting

### "401 Unauthorized" Errors

**Cause**: Invalid or missing API key

**Solutions**:
1. Verify your API key is correct:
   ```bash
   # Test with curl
   curl -X POST "${SERVICE_URL}/v1/completions" \
     -H "Content-Type: application/json" \
     -H "X-API-Key: sk-your-api-key-here" \
     -d '{"model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B", "prompt": "test", "max_tokens": 10}'
   ```

2. Ensure the `X-API-Key` header is configured in `opencode.json`

3. Verify the environment variable is set:
   ```bash
   echo $VLLM_API_KEY  # Linux/macOS
   echo %VLLM_API_KEY%  # Windows
   ```

### Connection Timeout

**Cause**: Cloud Run service is cold starting (first request after idle period)

**Solutions**:
- Wait 60-90 seconds for the first request (container needs to start)
- Consider setting `minInstances: 1` in Cloud Run configuration for instant responses
- Check service status:
  ```bash
  gcloud run services describe vllm-deepseek-r1-1-5b --region us-central1
  ```

### Model Not Found

**Cause**: Incorrect model ID in configuration

**Solution**: Ensure the model ID is exactly `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B` (case-sensitive)

### OpenCode Can't Find Provider

**Cause**: Invalid `opencode.json` syntax

**Solutions**:
1. Validate JSON syntax using [jsonlint.com](https://jsonlint.com)
2. Ensure `opencode.json` is in your project root or OpenCode config directory
3. Restart OpenCode after editing configuration

## Advanced Configuration

### Using Multiple Models

If you deploy multiple vLLM services with different models, add them all to `opencode.json`:

```json
{
  "provider": {
    "vllm-deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM DeepSeek R1",
      "options": {
        "baseURL": "https://vllm-deepseek-r1-1-5b-XXXXXXXXXX-uc.a.run.app/v1",
        "headers": {
          "X-API-Key": "{env:VLLM_API_KEY}"
        }
      },
      "models": {
        "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B": {
          "name": "DeepSeek R1 Distill Qwen 1.5B",
          "limit": {"context": 32768, "output": 4096}
        }
      }
    },
    "vllm-llama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM Llama 3.2",
      "options": {
        "baseURL": "https://vllm-llama-3-2-1b-XXXXXXXXXX-uc.a.run.app/v1",
        "headers": {
          "X-API-Key": "{env:VLLM_API_KEY}"
        }
      },
      "models": {
        "meta-llama/Llama-3.2-1B": {
          "name": "Llama 3.2 1B",
          "limit": {"context": 8192, "output": 2048}
        }
      }
    }
  }
}
```

### Custom Request Parameters

Add custom parameters to control generation behavior:

```json
{
  "provider": {
    "vllm-deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM DeepSeek R1",
      "options": {
        "baseURL": "https://vllm-deepseek-r1-1-5b-XXXXXXXXXX-uc.a.run.app/v1",
        "headers": {
          "X-API-Key": "{env:VLLM_API_KEY}"
        },
        "temperature": 0.7,
        "top_p": 0.9,
        "max_tokens": 2048
      },
      "models": {
        "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B": {
          "name": "DeepSeek R1 Distill Qwen 1.5B",
          "limit": {"context": 32768, "output": 4096}
        }
      }
    }
  }
}
```

## API Key Rotation

To rotate API keys without disrupting OpenCode:

1. **Generate a new API key** using the API key manager tool
2. **Update your environment variable** with the new key
3. **Reload keys on the server** (optional - keys auto-refresh on container restart):
   ```bash
   curl -X GET "${SERVICE_URL}/admin/reload-keys" \
     -H "X-API-Key: sk-your-current-key-here"
   ```
4. **Restart OpenCode** to pick up the new environment variable

## Cost Tracking

Every OpenCode request will be logged and tracked with your configured Google Cloud labels:
- `application: vllm-inference`
- `environment: production`
- `team: ml-platform`
- `cost-center: engineering`

View costs in Cloud Console → Billing → Reports, filtered by these labels.

## Performance Considerations

### Cold Start Times
- **First request**: 60-90 seconds (container initialization)
- **Subsequent requests**: < 1 second (warm container)
- **Mitigation**: Set `minInstances: 1` in Cloud Run for always-warm containers

### Model Context Length
- **Max context**: 32,768 tokens (~24,000 words)
- **Recommended output**: 2,048-4,096 tokens for code generation
- **Tip**: Use `@file` references strategically to stay within context limits

### Concurrent Requests
- **Default**: 1 request per container (configured in Cloud Run)
- **Scaling**: Cloud Run automatically spawns new containers for concurrent requests
- **Max instances**: 3 containers (configured in `cloudbuild.yaml`)

## Security Best Practices

1. **Never commit API keys** to version control
2. **Use environment variables** for API key configuration
3. **Rotate keys periodically** using the API key manager tool
4. **Monitor usage** in Cloud Run logs:
   ```bash
   gcloud run services logs read vllm-deepseek-r1-1-5b --region us-central1
   ```
5. **Set up billing alerts** to prevent unexpected costs

## Support and Additional Resources

- **vLLM Service Documentation**: See [CLAUDE.md](CLAUDE.md)
- **API Key Management**: [databitings-api-key-manager](https://github.com/patelmm79/databitings-api-key-manager)
- **OpenCode Documentation**: [opencode.ai/docs](https://opencode.ai/docs)
- **vLLM Documentation**: [docs.vllm.ai](https://docs.vllm.ai)

## Example Usage

Once configured, you can use OpenCode naturally:

```
# Ask questions about your codebase
What does the entrypoint.sh script do?

# Generate new features
Add error handling to the api_gateway.py file

# Refactor code
@api_gateway.py Optimize the key validation logic

# Debug issues
Why is my Cloud Run service returning 401 errors?
```

OpenCode will use your self-hosted vLLM service for all AI-powered responses!
