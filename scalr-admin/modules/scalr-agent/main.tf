locals {
  # SM secrets always live in the infra project (where ESO runs), not in the target project.
  sm_project_id = var.sm_project_id != null ? var.sm_project_id : var.infra_project_id
}

# GSA for the Scalr Agent in the target GCP project.
# The agent pod runs in the infra cluster but impersonates this GSA
# to manage resources in the target project via Workload Identity.
resource "google_service_account" "scalr_agent_gsa" {
  account_id   = var.scalr_agent_gsa_name
  display_name = "Scalr Agent - ${var.name} (Workload Identity)"
  project      = var.gcp_project_id
}

# Agent GSA can read/write Terraform state in GCS.
resource "google_storage_bucket_iam_member" "scalr_agent_state_bucket" {
  bucket = var.state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.scalr_agent_gsa.email}"
}

# WI binding: K8s ServiceAccount in the infra cluster → this GSA.
# Allows the agent pod to impersonate this GSA when calling GCP APIs.
resource "google_service_account_iam_member" "scalr_agent_wi" {
  service_account_id = google_service_account.scalr_agent_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  # WI pool is always identified by the CLUSTER project (infra), not the target project.
  # Cross-project WI: GSA lives in gcp_project_id, but the binding uses infra_project_id.
  member             = "serviceAccount:${var.infra_project_id}.svc.id.goog[${var.scalr_agent_namespace}/${var.scalr_agent_ksa}]"
}

# ESO reads this agent's JWT from SM and delivers it as a K8s Secret.
# This binding grants the shared ESO GSA access to the agent's token secret.
resource "google_secret_manager_secret_iam_member" "eso_read_token" {
  project   = local.sm_project_id
  secret_id = var.agent_pool_token_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.eso_gsa_email}"
}

# One Scalr agent pool per project. Workspaces are assigned to their
# project's agent pool so runs execute on the correct agent pod.
resource "scalr_agent_pool" "this" {
  name        = var.agent_pool_name
  vcs_enabled = var.agent_pool_vcs_enabled
}
