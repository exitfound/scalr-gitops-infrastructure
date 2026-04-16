output "scalr_agent_gsa_email" {
  description = "Email GSA для Scalr-агента — вставлять в fluxcd/infrastructure/scalr-agent/serviceaccount.yaml"
  value       = google_service_account.scalr_agent_gsa.email
}

output "eso_gsa_email" {
  description = "Email GSA для ESO — вставлять в fluxcd/infrastructure/external-secrets/serviceaccount.yaml"
  value       = google_service_account.eso_gsa.email
}
