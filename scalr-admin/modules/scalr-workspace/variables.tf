variable "account_id" {
  type        = string
  description = "Scalr account ID — required for scalr_variable resources when running locally"
}

variable "name" {
  type        = string
  description = "Workspace name"
}

variable "environment_id" {
  type        = string
  description = "Scalr environment ID to place the workspace in"
}

variable "execution_mode" {
  type        = string
  description = "remote — runs execute on agent; local — CLI-driven, agent stores state only"
  default     = "remote"

  validation {
    condition     = contains(["remote", "local"], var.execution_mode)
    error_message = "execution_mode must be 'remote' or 'local'."
  }
}

variable "terraform_version" {
  type        = string
  description = "Terraform version to use on the agent"
  default     = "1.5.7"
}

variable "auto_apply" {
  type        = bool
  description = "Automatically apply after a successful plan (no manual confirm)"
  default     = false
}

variable "agent_pool_id" {
  type        = string
  description = "Agent pool ID for remote execution. Required when execution_mode = remote"
  default     = null
}

# VCS — all null means CLI-driven workspace

variable "vcs_provider_id" {
  type        = string
  description = "VCS provider ID. When set the workspace becomes VCS-driven (PR→plan, merge→apply)"
  default     = null
}

variable "vcs_repo_identifier" {
  type        = string
  description = "Repository in format owner/repo. Required when vcs_provider_id is set"
  default     = null
}

variable "vcs_branch" {
  type        = string
  description = "Branch to track for VCS-driven runs"
  default     = "main"
}

variable "working_directory" {
  type        = string
  description = "Working directory within the repo. Use for monorepo layouts"
  default     = null
}

variable "trigger_prefixes" {
  type        = list(string)
  description = "Only trigger runs when files under these paths change (monorepo path filters)"
  default     = []
}

# Variables management
# Note: do not inline sensitive values in code — use Scalr UI or reference data sources instead.

variable "shell_variables" {
  type = list(object({
    key       = string
    value     = string
    sensitive = optional(bool, false)
  }))
  description = "Shell environment variables (GOOGLE_CREDENTIALS, custom env vars, etc.)"
  default     = []
}

variable "terraform_variables" {
  type = list(object({
    key       = string
    value     = string
    sensitive = optional(bool, false)
  }))
  description = "Terraform input variables (passed as TF_VAR_*)"
  default     = []
}
