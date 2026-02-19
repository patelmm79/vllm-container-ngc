terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

# Enable required APIs
resource "google_project_service" "required_apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# Create Artifact Registry repository for Docker images
resource "google_artifact_registry_repository" "vllm" {
  location      = var.gcp_region
  repository_id = var.artifact_registry_repo
  description   = "Docker repository for vLLM inference server images"
  format        = "DOCKER"

  depends_on = [google_project_service.required_apis]
}

# Create Secret Manager secret for HF_TOKEN
resource "google_secret_manager_secret" "hf_token" {
  secret_id = "HF_TOKEN"
  replication {
    automatic = true
  }

  depends_on = [google_project_service.required_apis]
}

# Create Secret Manager secret for API keys
resource "google_secret_manager_secret" "api_keys" {
  secret_id = var.api_keys_secret_name
  replication {
    automatic = true
  }

  depends_on = [google_project_service.required_apis]
}

# Get the default Compute Engine service account
data "google_compute_default_service_account" "default" {
  depends_on = [google_project_service.required_apis]
}

# Grant Secret Manager access to Cloud Run service account
resource "google_secret_manager_secret_iam_member" "hf_token_accessor" {
  secret_id = google_secret_manager_secret.hf_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

resource "google_secret_manager_secret_iam_member" "api_keys_accessor" {
  secret_id = google_secret_manager_secret.api_keys.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

# Service account for Cloud Build
resource "google_service_account" "cloud_build" {
  account_id   = "vllm-cloud-build"
  display_name = "vLLM Cloud Build Service Account"
}

# Grant Cloud Build service account necessary permissions
resource "google_project_iam_member" "cloud_build_editor" {
  project = var.gcp_project
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.cloud_build.email}"
}

resource "google_secret_manager_secret_iam_member" "hf_token_cloud_build" {
  secret_id = google_secret_manager_secret.hf_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_build.email}"
}

# Service account for Cloud Run invokers (optional - for external access)
resource "google_service_account" "run_invoker" {
  account_id   = "vllm-run-invoker"
  display_name = "vLLM Cloud Run Invoker"
}

# Grant Cloud Run invoker permission
resource "google_cloud_run_service_iam_member" "run_invoker" {
  service  = google_cloud_run_service.vllm.name
  location = var.gcp_region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.run_invoker.email}"
}

# Cloud Run service (placeholder - actual deployment via Cloud Build)
resource "google_cloud_run_service" "vllm" {
  name     = var.service_name
  location = var.gcp_region

  template {
    spec {
      service_account_name = data.google_compute_default_service_account.default.email

      containers {
        image = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project}/${var.artifact_registry_repo}/${var.artifact_registry_image}:latest"

        env {
          name  = "GCP_PROJECT"
          value = var.gcp_project
        }

        env {
          name  = "API_KEYS_SECRET_NAME"
          value = var.api_keys_secret_name
        }

        resources {
          limits = {
            cpu    = var.run_cpu
            memory = var.run_memory
          }
        }

        ports {
          container_port = 8000
        }
      }

      timeout_seconds = var.run_timeout
    }

    metadata {
      labels = {
        application = var.label_application
        environment = var.label_environment
        team        = var.label_team
        "cost-center" = var.label_cost_center
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  autogenerate_revision_name = true

  depends_on = [
    google_project_service.required_apis,
    google_artifact_registry_repository.vllm
  ]
}

# Cloud Run IAM - allow unauthenticated access
# Note: API Gateway still requires X-API-Key header for application-level security
resource "google_cloud_run_service_iam_member" "allow_unauthenticated" {
  service  = google_cloud_run_service.vllm.name
  location = var.gcp_region
  role     = "roles/run.invoker"
  member   = "principalSet:allUsers"
}
