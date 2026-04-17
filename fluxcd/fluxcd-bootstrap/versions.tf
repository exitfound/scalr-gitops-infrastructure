terraform {
  backend "gcs" {
    # Переопределяется через -backend-config="prefix=fluxcd-bootstrap/<cluster>"
    bucket = "terraform_state_dev_beneflo"
    prefix = "fluxcd-bootstrap/dev"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    flux = {
      source  = "fluxcd/flux2"
      version = "~> 1.8"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
  }
}
