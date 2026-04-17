module "env_dev" {
  source     = "./modules/scalr-environment"
  name       = "scalr-gcp-infrastructure-dev"
  account_id = var.scalr_account_id
}
