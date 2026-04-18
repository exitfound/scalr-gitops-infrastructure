output "gsa_email" {
  description = "ESO GSA email — used by fluxcd-bootstrap for WI annotation and by scalr-agent modules for SM IAM"
  value       = google_service_account.this.email
}
