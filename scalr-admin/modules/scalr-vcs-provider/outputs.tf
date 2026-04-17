output "vcs_provider_id" {
  description = "Scalr VCS provider ID — use as vcs_provider_id in scalr-workspace module"
  value       = scalr_vcs_provider.this.id
}

output "name" {
  description = "Scalr VCS provider name"
  value       = scalr_vcs_provider.this.name
}
