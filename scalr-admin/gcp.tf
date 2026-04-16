# ===========================================================================
# Scalr Agent — GCP Service Account + Workload Identity binding
# ===========================================================================

resource "google_service_account" "scalr_agent_gsa" {
  account_id   = "scalr-agent-gsa"
  display_name = "Scalr Agent (Workload Identity)"
  project      = var.gcp_project_id
}

resource "google_storage_bucket_iam_member" "scalr_agent_state_bucket" {
  bucket = var.state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.scalr_agent_gsa.email}"
}

resource "google_service_account_iam_binding" "scalr_agent_wi" {
  service_account_id = google_service_account.scalr_agent_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.gcp_project_id}.svc.id.goog[${var.scalr_agent_namespace}/${var.scalr_agent_ksa}]",
  ]
}

# ===========================================================================
# External Secrets Operator — GCP Service Account + Workload Identity binding
# ===========================================================================

resource "google_service_account" "eso_gsa" {
  account_id   = "eso-gsa"
  display_name = "External Secrets Operator (Workload Identity)"
  project      = var.gcp_project_id
}

resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso_gsa.email}"
}

resource "google_service_account_iam_binding" "eso_wi" {
  service_account_id = google_service_account.eso_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.gcp_project_id}.svc.id.goog[${var.eso_namespace}/${var.eso_ksa}]",
  ]
}
