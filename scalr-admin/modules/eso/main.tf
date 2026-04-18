resource "google_service_account" "this" {
  account_id   = "eso-gsa"
  display_name = "External Secrets Operator (Workload Identity)"
  project      = var.project
}

# WI binding: K8s ServiceAccount in the infra cluster → this GSA.
# project in member = the GKE cluster project (always the infra project).
resource "google_service_account_iam_member" "wi" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${var.namespace}/${var.ksa}]"
}
