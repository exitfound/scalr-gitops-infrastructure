terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    bucket = "scalr-infrastructure-bucket"
    prefix = "gcp-sample-project"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
