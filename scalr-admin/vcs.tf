module "vcs_github" {
  source     = "./modules/scalr-vcs-provider"
  name       = "github-${var.github_username}"
  account_id = var.scalr_account_id
  vcs_type   = "github"
  token      = data.google_secret_manager_secret_version.github_pat.secret_data
}
