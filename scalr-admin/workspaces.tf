module "ws_admin" {
  source         = "./modules/scalr-workspace"
  account_id     = "acc-v0p7ctljql63n2eg4"
  environment_id = module.env_main.environment_id
  name           = "scalr-admin-workspace"
  execution_mode = "local"
  terraform_version = "1.5.7"
  auto_apply     = false
}

module "ws_gcp_sample_project" {
  source              = "./modules/scalr-workspace"
  account_id          = "acc-v0p7ctljql63n2eg4"
  name                = "gcp-sample-project"
  environment_id      = module.env_main.environment_id
  execution_mode      = "remote"
  terraform_version   = "1.5.7"
  auto_apply          = false

  agent_pool_id       = module.agent_main.agent_pool_id

  vcs_provider_id     = module.vcs_github.vcs_provider_id
  vcs_repo_identifier = "exitfound/scalr-gitops-infrastructure"
  vcs_branch          = "main"
  working_directory   = "gcp-sample-project"
  trigger_prefixes    = ["gcp-sample-project"]

  terraform_variables = [
    { key = "gcp_project_id", value = "beneflo-main",             sensitive = false },
    { key = "bucket_name",    value = "scalr-sample-bucket-test", sensitive = false },
  ]
}
