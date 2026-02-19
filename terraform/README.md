# Terraform Infrastructure for vLLM on Cloud Run

This Terraform configuration automates the setup of all required GCP infrastructure for the vLLM inference server on Cloud Run.

## What It Creates

- **Artifact Registry Repository** - Docker image storage
- **Secret Manager Secrets** - `HF_TOKEN` and `vllm-api-keys`
- **Service Accounts** - For Cloud Build and Cloud Run access
- **IAM Roles** - Proper permissions for all services
- **Cloud Run Service** - The actual inference service
- **API Enablement** - Enables all required GCP APIs

## Prerequisites

1. **Terraform installed** (v1.0+)
2. **gcloud CLI authenticated** - `gcloud auth application-default login`
3. **GCP project selected** - `gcloud config set project YOUR_PROJECT_ID`
4. **Appropriate IAM permissions** - Editor or Owner role

## Quick Start

### 1. Create `terraform.tfvars`

Copy the example and fill in your values from `config.env`:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
gcp_project              = "globalbiting-dev"
service_name             = "vllm-qwen-25-3b-instruct"
artifact_registry_repo   = "vllm-qwen-25-3b-repo"
artifact_registry_image  = "vllm-qwen-25-3b-instruct"
```

### 2. Initialize Terraform

```bash
cd terraform
terraform init
```

### 3. Plan the deployment

```bash
terraform plan
```

Review the resources that will be created.

### 4. Apply the configuration

```bash
terraform apply
```

Type `yes` when prompted to create the infrastructure.

## What to Do After Terraform

Once Terraform completes successfully:

1. **Set the HF_TOKEN secret** (required before Cloud Build):
   ```bash
   echo -n "your-huggingface-token" | gcloud secrets versions add HF_TOKEN --data-file=-
   ```

2. **Set the API keys secret** (optional, can be set later):
   ```bash
   echo -n '{"my-service": "sk-abc123..."}' | gcloud secrets versions add vllm-api-keys --data-file=-
   ```

3. **Build and deploy** via Cloud Build:
   ```bash
   gcloud builds submit --config cloudbuild.yaml
   ```

## Key Outputs

After `terraform apply`, check the outputs:

```bash
terraform output
```

This shows:
- `artifact_registry_url` - Where Docker images are stored
- `cloud_run_service_url` - URL of your deployed service
- `service_account_email` - Cloud Run service account
- `hf_token_secret_name` - Where HF_TOKEN is stored

## Updating Infrastructure

If you need to change settings (CPU, memory, labels, etc.):

1. Update `terraform.tfvars`
2. Run `terraform plan` to see changes
3. Run `terraform apply` to apply changes

## Destroying Infrastructure

**Warning**: This will delete all infrastructure including data.

```bash
terraform destroy
```

## Troubleshooting

### "API not enabled" errors
Terraform will automatically enable required APIs. If you see errors, ensure you have Editor or Owner permissions.

### "Secret already exists" errors
If you already have secrets with the same names, either:
- Use different secret names in `terraform.tfvars`, or
- Delete existing secrets with: `gcloud secrets delete SECRET_NAME`

### "Repository already exists" errors
If the Artifact Registry repo exists, either:
- Use a different repository name in `terraform.tfvars`, or
- Delete the repo with: `gcloud artifacts repositories delete REPO_NAME --location=REGION`

## Advanced: GitOps Workflow

For team environments, store Terraform state in Google Cloud Storage:

```bash
# Create a bucket for Terraform state
gsutil mb gs://YOUR_PROJECT_ID-terraform-state

# Add to terraform/main.tf:
terraform {
  backend "gcs" {
    bucket = "YOUR_PROJECT_ID-terraform-state"
    prefix = "vllm-inference"
  }
}

# Then reinitialize:
terraform init
```

## Files

- `main.tf` - Main infrastructure definition
- `variables.tf` - Variable definitions
- `outputs.tf` - Output values
- `terraform.tfvars.example` - Example variables (copy to terraform.tfvars)

## Related Documentation

- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest)
- [GCP vLLM Project README](../CLAUDE.md)
- [Cloud Build Configuration](../cloudbuild.yaml)
