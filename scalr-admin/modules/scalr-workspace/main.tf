resource "scalr_workspace" "this" {
  name              = var.name
  environment_id    = var.environment_id
  terraform_version = var.terraform_version
  execution_mode    = var.execution_mode
  auto_apply        = var.auto_apply
  agent_pool_id     = var.agent_pool_id
  working_directory = var.working_directory
  vcs_provider_id   = var.vcs_provider_id

  dynamic "vcs_repo" {
    for_each = var.vcs_provider_id != null ? [1] : []
    content {
      identifier       = var.vcs_repo_identifier
      branch           = var.vcs_branch
      trigger_prefixes = var.trigger_prefixes
    }
  }

  lifecycle {
    precondition {
      condition     = var.vcs_provider_id == null || var.vcs_repo_identifier != null
      error_message = "vcs_repo_identifier must be set when vcs_provider_id is provided."
    }
    precondition {
      condition     = var.execution_mode != "remote" || var.agent_pool_id != null
      error_message = "agent_pool_id must be set when execution_mode is 'remote'."
    }
  }
}

resource "scalr_variable" "shell" {
  for_each = { for v in var.shell_variables : v.key => v }

  key          = each.value.key
  value        = each.value.value
  category     = "shell"
  sensitive    = each.value.sensitive
  workspace_id = scalr_workspace.this.id
}

resource "scalr_variable" "terraform" {
  for_each = { for v in var.terraform_variables : v.key => v }

  key          = each.value.key
  value        = each.value.value
  category     = "terraform"
  sensitive    = each.value.sensitive
  workspace_id = scalr_workspace.this.id
}
