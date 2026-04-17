output "agent_pool_id" {
  description = "Scalr agent pool ID — use as agent_pool_id in scalr-workspace module"
  value       = scalr_agent_pool.this.id
}

output "name" {
  description = "Scalr agent pool name"
  value       = scalr_agent_pool.this.name
}
