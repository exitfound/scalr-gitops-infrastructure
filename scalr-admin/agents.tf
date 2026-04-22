module "agent_main" {
  source = "./modules/scalr-agent"

  name                         = "main"
  gcp_project_id               = "beneflo-main"
  infra_project_id             = var.gcp_project_id
  scalr_agent_gsa_name         = "scalr-agent-gsa"
  scalr_agent_namespace        = "scalr-agent"
  scalr_agent_ksa              = "scalr-agent"
  state_bucket                 = "scalr-infrastructure-bucket"
  agent_pool_name              = "scalr-gitops-infrastructure-agent"
  agent_pool_vcs_enabled       = false
  agent_pool_token_secret_name = "scalr-agent-pool-token"
  eso_gsa_email                = module.eso.gsa_email

  project_roles = [
    "roles/storage.admin",
  ]
}


# To add a new agent in a different GCP project, copy this block and change the values.
# infra_project_id stays the same (cluster never moves).
# gcp_project_id changes to the target project.
# scalr_agent_namespace and scalr_agent_ksa MUST be unique per agent — they form the WI binding principal.
#
# module "agent_prod" {
#   source = "./modules/scalr-agent"
#   name                         = "prod"
#   gcp_project_id               = "beneflo-gcp-project-prod"
#   infra_project_id             = var.gcp_project_id
#   scalr_agent_gsa_name         = "scalr-agent-gsa-prod"
#   scalr_agent_namespace        = "scalr-agent-prod"
#   scalr_agent_ksa              = "scalr-agent-prod"
#   state_bucket                 = "terraform_state_prod"
#   agent_pool_name              = "scalr-gitops-infrastructure-agent-prod"
#   agent_pool_vcs_enabled       = false
#   agent_pool_token_secret_name = "scalr-agent-pool-token-prod"
#   eso_gsa_email                = module.eso.gsa_email
# }
