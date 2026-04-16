variable "project_id" {
  type        = string
  description = "GCP Project ID"
  default     = "beneflo-gcp-project-dev"
}

variable "region" {
  type        = string
  description = "GCP Region"
  default     = "europe-north2"
}

# Namespace и KSA для Scalr-агента (должны совпадать с fluxcd/infrastructure/scalr-agent/)
variable "scalr_agent_namespace" {
  type    = string
  default = "scalr-agent"
}

variable "scalr_agent_ksa" {
  type    = string
  default = "scalr-agent"
}

# Namespace и KSA для External Secrets Operator (должны совпадать с fluxcd/infrastructure/external-secrets/)
variable "eso_namespace" {
  type    = string
  default = "external-secrets"
}

variable "eso_ksa" {
  type    = string
  default = "external-secrets"
}
