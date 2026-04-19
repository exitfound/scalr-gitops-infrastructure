locals {
  eso_gsa_email = data.terraform_remote_state.scalr_admin.outputs.eso_gsa_email
  agents        = data.terraform_remote_state.scalr_admin.outputs.agents
}

output "flux_version_installed" {
  description = "Flux version installed on the cluster"
  value       = flux_bootstrap_git.this.version
}

output "flux_bootstrap_path" {
  description = "Git path where Flux committed gotk-components.yaml and gotk-sync.yaml"
  value       = flux_bootstrap_git.this.path
}

output "eso_gsa_email" {
  description = "ESO GSA email — use as WI annotation in fluxcd/infrastructure/external-secrets/serviceaccount.yaml"
  value       = local.eso_gsa_email
}

output "scalr_agent_gsa_emails" {
  description = "Scalr Agent GSA emails keyed by agent name — use as WI annotation in fluxcd/infrastructure/scalr-agent-{name}/serviceaccount.yaml"
  value       = { for k, v in local.agents : k => v.scalr_agent_gsa_email }
}

output "gke_cluster_endpoint" {
  description = "GKE cluster API server endpoint"
  value       = data.google_container_cluster.gke.endpoint
  sensitive   = true
}
