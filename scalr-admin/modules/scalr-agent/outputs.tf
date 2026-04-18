output "scalr_agent_gsa_email" {
  description = "GSA email for Scalr Agent — consumed by fluxcd-bootstrap via terraform_remote_state"
  value       = google_service_account.scalr_agent_gsa.email
}

output "agent_pool_id" {
  description = "Scalr agent pool ID — use as agent_pool_id in scalr-workspace module"
  value       = scalr_agent_pool.this.id
}

output "agent_pool_name" {
  description = "Scalr agent pool name"
  value       = scalr_agent_pool.this.name
}

output "namespace" {
  description = "K8s namespace where the Scalr Agent pod runs — used by fluxcd-bootstrap for serviceaccount.yaml"
  value       = var.scalr_agent_namespace
}

output "ksa" {
  description = "K8s ServiceAccount name used by the Scalr Agent pod"
  value       = var.scalr_agent_ksa
}
