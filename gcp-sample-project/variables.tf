variable "gcp_project_id" {
  type        = string
  description = "GCP project where resources are created"
}

variable "gcp_region" {
  type        = string
  description = "GCP region for resources"
  default     = "europe-north2"
}

variable "bucket_name" {
  type        = string
  description = "Name of the GCS bucket to create (must be globally unique)"
}
