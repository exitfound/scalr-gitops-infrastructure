module "vcs_github" {
  source     = "./modules/scalr-vcs-provider"
  name       = "github-exitfound"
  account_id = "acc-v0p7ctljql63n2eg4"
  vcs_type   = "github"
  token      = data.google_secret_manager_secret_version.github_pat.secret_data
}
