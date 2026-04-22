variable "name" {
  type        = string
  description = "Logical name of this agent (dev, prod, staging)"
}

variable "gcp_project_id" {
  type        = string
  description = "GCP project where the agent GSA is created and Terraform resources are managed"
}

variable "scalr_agent_gsa_name" {
  type        = string
  description = "GCP service account ID for the Scalr Agent GSA (must be unique within the GCP project)"
}

variable "state_bucket" {
  type        = string
  description = "GCS bucket for Terraform state (used for IAM binding)"
}

variable "agent_pool_name" {
  type        = string
  description = "Scalr agent pool display name"
}

variable "agent_pool_vcs_enabled" {
  type        = bool
  description = "Whether the agent pool supports VCS-driven workspaces"
  default     = true
}

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

variable "infra_project_id" {
  type        = string
  description = "GCP project where the GKE cluster (WI pool) and SM secrets live. For Option A (one infra cluster) this is always the infra/scalr project, regardless of which GCP project the agent manages."
}

variable "eso_gsa_email" {
  type        = string
  description = "Email of the shared ESO GSA — used to grant SM read access for this agent's token"
}

variable "sm_project_id" {
  type        = string
  description = "GCP project where the agent pool token SM secret lives. Defaults to infra_project_id."
  default     = null
}

variable "agent_pool_token_secret_name" {
  type        = string
  description = "SM secret name containing the Scalr agent pool JWT"
  default     = "scalr-agent-pool-token"
}

variable "project_roles" {
  type        = list(string)
  description = "IAM roles granted to the agent GSA at project level in gcp_project_id. Use for agents that need to create/manage GCP resources (e.g. roles/storage.admin)."
  default     = []
}

