# ===========================================================================
# Scalr agent — GCP Service Account + Workload Identity binding
# ===========================================================================

resource "google_service_account" "scalr_agent_gsa" {
  account_id   = "scalr-agent-gsa"
  display_name = "Scalr Agent (Workload Identity)"
  project      = var.project_id
}

# Роли подгоняешь под то, чем будет заниматься Terraform в Scalr workspace-ах.
# На старте — минимум. Расширяешь по мере появления реальных workspace-ов.
resource "google_project_iam_member" "scalr_agent_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.scalr_agent_gsa.email}"
}

resource "google_service_account_iam_binding" "scalr_agent_wi" {
  service_account_id = google_service_account.scalr_agent_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.scalr_agent_namespace}/${var.scalr_agent_ksa}]",
  ]
}

# ===========================================================================
# External Secrets Operator — GCP Service Account + Workload Identity binding
# ===========================================================================

resource "google_service_account" "eso_gsa" {
  account_id   = "eso-gsa"
  display_name = "External Secrets Operator (Workload Identity)"
  project      = var.project_id
}

resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso_gsa.email}"
}

resource "google_service_account_iam_binding" "eso_wi" {
  service_account_id = google_service_account.eso_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.eso_namespace}/${var.eso_ksa}]",
  ]
}

# ===========================================================================
# Secret Manager — плейсхолдеры
# Значения НЕ кладём в Terraform — зальём через gcloud после apply,
# чтобы они не попали в state.
# ===========================================================================

resource "google_secret_manager_secret" "scalr_agent_pool_token" {
  secret_id = "scalr-agent-pool-token"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "scalr_api_token" {
  secret_id = "scalr-api-token"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "github_pat" {
  secret_id = "github-pat"
  project   = var.project_id

  replication {
    auto {}
  }
}
