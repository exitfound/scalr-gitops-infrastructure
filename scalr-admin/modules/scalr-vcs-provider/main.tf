resource "scalr_vcs_provider" "this" {
  name       = var.name
  account_id = var.account_id
  vcs_type   = var.vcs_type
  token      = var.token
}
