terraform {
  backend "gcs" {
    # Переопределяется через -backend-config:
    #   terraform init -backend-config="bucket=YOUR_BUCKET" -backend-config="prefix=fluxcd-bootstrap/<cluster>"
    bucket = "terraform_state_dev_beneflo"
    prefix = "fluxcd-bootstrap/scalr"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.8"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
  }
}
