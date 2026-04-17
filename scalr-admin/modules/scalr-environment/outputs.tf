output "environment_id" {
  description = "Scalr environment ID — use as environment_id in scalr-workspace module"
  value       = scalr_environment.this.id
}

output "name" {
  description = "Scalr environment name"
  value       = scalr_environment.this.name
}
