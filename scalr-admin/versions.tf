terraform {
  backend "gcs" {
    bucket = "terraform_state_dev_beneflo"
    prefix = "scalr-admin"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    scalr = {
      source  = "scalr/scalr"
      version = "~> 3.15"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "scalr" {
  hostname = "kitezh.scalr.io"
  # export SCALR_TOKEN=$(gcloud secrets versions access latest --secret=scalr-api-token --project=PROJECT)
}
