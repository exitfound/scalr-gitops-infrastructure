output "scalr_agent_gsa_email" {
  description = "GSA email for Scalr Agent — paste into fluxcd/infrastructure/scalr-agent/serviceaccount.yaml"
  value       = google_service_account.scalr_agent_gsa.email
}

output "eso_gsa_email" {
  description = "GSA email for ESO — paste into fluxcd/infrastructure/external-secrets/serviceaccount.yaml"
  value       = google_service_account.eso_gsa.email
}

output "scalr_environment_id" {
  description = "Scalr environment ID — use as environment_id in scalr-workspace module"
  value       = module.env_dev.environment_id
}

output "scalr_agent_pool_id" {
  description = "Scalr agent pool ID — use as agent_pool_id in scalr-workspace module"
  value       = module.agent_pool.agent_pool_id
}

output "scalr_vcs_provider_id" {
  description = "Scalr VCS provider ID — use as vcs_provider_id in scalr-workspace module"
  value       = module.vcs_github.vcs_provider_id
}
