variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "service_name" {
  description = "Cloud Run service name"
  type        = string
}

variable "artifact_registry_repo" {
  description = "Artifact Registry repository name"
  type        = string
}

variable "artifact_registry_image" {
  description = "Docker image name in Artifact Registry"
  type        = string
}

variable "api_keys_secret_name" {
  description = "Secret Manager secret name for API keys"
  type        = string
  default     = "vllm-api-keys"
}

variable "run_cpu" {
  description = "Cloud Run CPU allocation"
  type        = string
  default     = "8"
}

variable "run_memory" {
  description = "Cloud Run memory allocation"
  type        = string
  default     = "32Gi"
}

variable "run_timeout" {
  description = "Cloud Run request timeout in seconds"
  type        = number
  default     = 600
}

variable "label_application" {
  description = "Application label"
  type        = string
  default     = "vllm-inference"
}

variable "label_environment" {
  description = "Environment label"
  type        = string
  default     = "production"
}

variable "label_team" {
  description = "Team label"
  type        = string
  default     = "ml-platform"
}

variable "label_cost_center" {
  description = "Cost center label"
  type        = string
  default     = "engineering"
}
