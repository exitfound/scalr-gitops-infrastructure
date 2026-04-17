output "workspace_id" {
  description = "Scalr workspace ID"
  value       = scalr_workspace.this.id
}

output "name" {
  description = "Scalr workspace name"
  value       = scalr_workspace.this.name
}
