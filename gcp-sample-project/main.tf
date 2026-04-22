resource "google_storage_bucket" "sample" {
  name          = var.bucket_name
  project       = var.gcp_project_id
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = false
  }

  labels = {
    managed-by  = "scalr"
    project     = "gcp-sample-project"
    environment = "dev"
  }
}
