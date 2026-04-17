variable "name" {
  type        = string
  description = "VCS provider display name in Scalr"
}

variable "account_id" {
  type        = string
  description = "Scalr account ID"
}

variable "vcs_type" {
  type        = string
  description = "VCS type: github, gitlab, bitbucket_hosted, azure_dev_ops_services"
  default     = "github"
}

variable "token" {
  type        = string
  description = "Personal access token for the VCS provider"
  sensitive   = true
}
