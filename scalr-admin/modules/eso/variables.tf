variable "project" {
  type        = string
  description = "GCP project where ESO GSA is created and the GKE cluster (WI pool) lives"
}

variable "namespace" {
  type        = string
  description = "K8s namespace where the ESO pod runs"
  default     = "external-secrets"
}

variable "ksa" {
  type        = string
  description = "K8s ServiceAccount name used by the ESO pod"
  default     = "external-secrets"
}
