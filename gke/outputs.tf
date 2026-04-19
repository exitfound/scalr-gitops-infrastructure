output "cluster_name" {
  description = "GKE cluster resource name"
  value       = module.gke.cluster_name
}

output "cluster_endpoint" {
  description = "GKE API server endpoint"
  value       = module.gke.endpoint
  sensitive   = true
}

output "cluster_endpoint_dns" {
  description = "GKE API server DNS endpoint"
  value       = module.gke.endpoint_dns
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.gke.ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "GKE cluster location"
  value       = module.gke.location
}

output "project_id" {
  description = "GCP project ID"
  value       = var.gcp_project_id
}

output "network_name" {
  description = "VPC network name"
  value       = module.vpc.network_name
}

output "subnet_name" {
  description = "Subnet name"
  value       = var.subnet_name
}

output "workload_pool" {
  description = "Workload Identity pool (PROJECT.svc.id.goog)"
  value       = local.workload_pool
}
