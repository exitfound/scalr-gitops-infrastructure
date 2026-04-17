resource "scalr_agent_pool" "this" {
  name        = var.name
  vcs_enabled = var.vcs_enabled
}
