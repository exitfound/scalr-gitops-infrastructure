variable "cluster_name" {
  type        = string
  description = "Logical cluster name used for Flux path and state prefix (dev, prod, staging)"
}

variable "gke_cluster_name" {
  type        = string
  description = "GKE cluster resource name as shown in GCP (e.g. dev-cluster)"
}

variable "gke_location" {
  type        = string
  description = "GKE cluster zone or region (e.g. europe-north2 or europe-north2-a)"
  default     = "europe-north2"
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID"
}

variable "gcp_region" {
  type        = string
  description = "GCP region for the Google provider"
  default     = "europe-north2"
}

variable "state_bucket" {
  type        = string
  description = "GCS bucket holding Terraform state (shared with scalr-admin)"
}

variable "scalr_admin_state_prefix" {
  type        = string
  description = "GCS prefix of scalr-admin state used for terraform_remote_state"
  default     = "scalr-admin"
}

variable "github_org" {
  type        = string
  description = "GitHub organisation or user owning the repository"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name (without org)"
}

variable "github_branch" {
  type        = string
  description = "Branch Flux watches"
  default     = "main"
}

variable "github_pat_secret_name" {
  type        = string
  description = "GCP Secret Manager secret name containing the GitHub PAT"
  default     = "github-pat"
}

variable "flux_version" {
  type        = string
  description = "Flux version to install (omit v prefix), e.g. 2.8.5"
  default     = "2.8.5"
}
