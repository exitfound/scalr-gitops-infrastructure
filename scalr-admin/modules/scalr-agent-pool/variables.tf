variable "name" {
  type        = string
  description = "Name of the Scalr agent pool"
}

variable "vcs_enabled" {
  type        = bool
  description = "Enable VCS agent pool. Must be true for VCS-driven workspaces"
  default     = true
}
