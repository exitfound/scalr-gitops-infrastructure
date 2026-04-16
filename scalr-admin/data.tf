data "google_secret_manager_secret_version" "github_pat" {
  secret  = var.github_secret_name
  project = var.gcp_project_id
}
