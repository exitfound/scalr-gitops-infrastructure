output "bucket_name" {
  description = "Name of the created GCS bucket"
  value       = google_storage_bucket.sample.name
}

output "bucket_url" {
  description = "GCS URL of the bucket"
  value       = google_storage_bucket.sample.url
}
