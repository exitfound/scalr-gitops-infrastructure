output "flux_version_installed" {
  description = "Flux version installed on the cluster"
  value       = flux_bootstrap_git.this.version
}

output "flux_bootstrap_path" {
  description = "Git path where Flux committed gotk-components.yaml and gotk-sync.yaml"
  value       = flux_bootstrap_git.this.path
}

output "eso_gsa_email_applied" {
  description = "GSA email written into ESO ServiceAccount"
  value       = local.eso_gsa_email
}

output "scalr_agent_gsa_emails_applied" {
  description = "GSA emails written into Scalr Agent ServiceAccounts, keyed by agent name"
  value       = { for k, v in local.agents : k => v.scalr_agent_gsa_email }
}

output "gke_cluster_endpoint" {
  description = "GKE cluster API server endpoint"
  value       = data.google_container_cluster.gke.endpoint
  sensitive   = true
}
