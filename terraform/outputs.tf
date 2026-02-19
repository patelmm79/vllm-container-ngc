output "artifact_registry_url" {
  description = "Artifact Registry repository URL"
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project}/${var.artifact_registry_repo}"
}

output "cloud_run_service_url" {
  description = "Cloud Run service URL"
  value       = google_cloud_run_service.vllm.status[0].url
}

output "service_account_email" {
  description = "Cloud Run service account email"
  value       = data.google_compute_default_service_account.default.email
}

output "cloud_build_service_account" {
  description = "Cloud Build service account email"
  value       = google_service_account.cloud_build.email
}

output "run_invoker_service_account" {
  description = "Cloud Run invoker service account email"
  value       = google_service_account.run_invoker.email
}

output "hf_token_secret_name" {
  description = "HF_TOKEN Secret Manager secret name"
  value       = google_secret_manager_secret.hf_token.id
}

output "api_keys_secret_name" {
  description = "API Keys Secret Manager secret name"
  value       = google_secret_manager_secret.api_keys.id
}
