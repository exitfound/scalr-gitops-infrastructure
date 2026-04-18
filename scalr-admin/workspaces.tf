module "ws_admin" {
  source            = "./modules/scalr-workspace"
  environment_id    = module.env_dev.environment_id
  name              = "scalr-admin-workspace"
  execution_mode    = "local"
  terraform_version = "1.5.7"
  auto_apply        = false
}
