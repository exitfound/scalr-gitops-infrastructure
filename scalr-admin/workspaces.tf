resource "scalr_workspace" "admin" {
  name              = "scalr-admin-workspace"
  environment_id    = scalr_environment.this.id
  terraform_version = var.terraform_version
  execution_mode    = "local"
  auto_apply        = false
}
