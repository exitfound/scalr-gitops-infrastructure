# === GCP ===

variable "gcp_project_id" {
  type        = string
  description = "GCP project where ESO GSA, SM secrets, and shared resources live"
}

variable "gcp_region" {
  type        = string
  description = "GCP region for the Google provider"
  default     = "europe-north2"
}

# === K8s namespace/KSA for shared ESO (must match fluxcd/infrastructure/external-secrets/ manifests) ===

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
