# === GCP ===

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID where GSA and WI bindings are created"
}

variable "gcp_region" {
  type        = string
  description = "GCP region for the Google provider"
  default     = "europe-north2"
}

# === Scalr ===

variable "scalr_hostname" {
  type        = string
  description = "Scalr account hostname, e.g. myaccount.scalr.io"
}

variable "scalr_account_id" {
  type        = string
  description = "Scalr account ID, visible in UI URL: .../accounts/acc-.../..."
}

# === GitHub ===

variable "github_username" {
  type        = string
  description = "GitHub username used as part of the VCS provider name"
}

variable "github_secret_name" {
  type        = string
  description = "GCP Secret Manager secret name containing the GitHub PAT"
  default     = "github-pat"
}

variable "scalr_api_token_secret_name" {
  type        = string
  description = "GCP Secret Manager secret name containing the Scalr API token (used via SCALR_TOKEN env var)"
  default     = "scalr-api-token"
}

variable "scalr_agent_pool_token_secret_name" {
  type        = string
  description = "GCP Secret Manager secret name containing the Scalr Agent Pool JWT (read by ESO)"
  default     = "scalr-agent-pool-token"
}

# === K8s namespace/KSA (must match fluxcd/infrastructure/ manifests) ===

variable "scalr_agent_namespace" {
  type        = string
  description = "K8s namespace where the Scalr Agent pod runs"
  default     = "scalr-agent"
}

variable "scalr_agent_ksa" {
  type        = string
  description = "K8s ServiceAccount name used by the Scalr Agent pod"
  default     = "scalr-agent"
}

variable "eso_namespace" {
  type        = string
  description = "K8s namespace where External Secrets Operator runs"
  default     = "external-secrets"
}

variable "eso_ksa" {
  type        = string
  description = "K8s ServiceAccount name used by the ESO pod"
  default     = "external-secrets"
}

variable "state_bucket" {
  type        = string
  description = "GCS bucket name used for Terraform state (used for IAM binding)"
  default     = "terraform_state_dev_beneflo"
}
