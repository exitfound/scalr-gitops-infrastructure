terraform {
  backend "gcs" {
    bucket = "terraform_state_dev_beneflo"
    prefix = "scalr-gitops"
  }
}
