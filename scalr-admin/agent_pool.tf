module "agent_pool" {
  source      = "./modules/scalr-agent-pool"
  name        = "scalr-gitops-infrastructure-agent"
  vcs_enabled = false
}
