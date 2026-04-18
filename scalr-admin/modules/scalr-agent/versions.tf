terraform {
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
