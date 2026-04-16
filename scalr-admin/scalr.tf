resource "scalr_agent_pool" "this" {
  name = var.agent_pool_name
}

resource "scalr_environment" "this" {
  name       = var.environment_name
  account_id = var.scalr_account_id
}

resource "scalr_vcs_provider" "github" {
  name       = "github-${var.github_username}"
  account_id = var.scalr_account_id
  vcs_type   = "github"
  token      = data.google_secret_manager_secret_version.github_pat.secret_data
}

