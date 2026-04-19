output "agents" {
  description = "Per-agent outputs keyed by agent name — consumed by fluxcd-bootstrap via terraform_remote_state"
  value = {
    dev = {
      scalr_agent_gsa_email = module.agent_dev.scalr_agent_gsa_email
      agent_pool_id         = module.agent_dev.agent_pool_id
      agent_pool_name       = module.agent_dev.agent_pool_name
      namespace             = module.agent_dev.namespace
      ksa                   = module.agent_dev.ksa
    }
    test = {
      scalr_agent_gsa_email = module.agent_test.scalr_agent_gsa_email
      agent_pool_id         = module.agent_test.agent_pool_id
      agent_pool_name       = module.agent_test.agent_pool_name
      namespace             = module.agent_test.namespace
      ksa                   = module.agent_test.ksa
    }
  }
}

output "eso_gsa_email" {
  description = "GSA email for ESO — consumed by fluxcd-bootstrap via terraform_remote_state"
  value       = module.eso.gsa_email
}

output "scalr_environment_id" {
  description = "Scalr environment ID — use as environment_id in scalr-workspace module"
  value       = module.env_dev.environment_id
}

output "scalr_agent_pool_ids" {
  description = "Map of agent name → Scalr agent pool ID"
  value = {
    dev  = module.agent_dev.agent_pool_id
    test = module.agent_test.agent_pool_id
  }
}

output "scalr_vcs_provider_id" {
  description = "Scalr VCS provider ID — use as vcs_provider_id in scalr-workspace module"
  value       = module.vcs_github.vcs_provider_id
}
