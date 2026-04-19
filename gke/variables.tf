variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for the cluster and network resources"
  type        = string
  default     = "europe-north2"
}

variable "cluster_name" {
  description = "GKE cluster resource name"
  type        = string
}

variable "network_name" {
  description = "VPC network name"
  type        = string
  default     = "gke-network"
}

variable "subnet_name" {
  description = "Subnet name for GKE nodes"
  type        = string
  default     = "gke-subnet"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the subnet (node IPs)"
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_range_name" {
  description = "Name of the secondary range for GKE pods"
  type        = string
  default     = "gke-pods"
}

variable "pods_cidr" {
  description = "CIDR range for GKE pods (min /14 recommended)"
  type        = string
  default     = "10.4.0.0/14"
}

variable "services_range_name" {
  description = "Name of the secondary range for GKE services"
  type        = string
  default     = "gke-services"
}

variable "services_cidr" {
  description = "CIDR range for GKE services (ClusterIP)"
  type        = string
  default     = "10.8.0.0/20"
}

variable "master_cidr" {
  description = "CIDR range for the GKE control plane (requires /28)"
  type        = string
  default     = "172.16.0.0/28"
}

variable "router_name" {
  description = "Cloud Router name"
  type        = string
  default     = "gke-router"
}

variable "nat_name" {
  description = "Cloud NAT name"
  type        = string
  default     = "gke-nat"
}

variable "router_asn" {
  description = "ASN for the Cloud Router"
  type        = string
  default     = "65001"
}

variable "maintenance_window_start" {
  description = "Daily maintenance window start time (UTC, HH:MM format)"
  type        = string
  default     = "05:00"
}

variable "master_authorized_networks" {
  description = "CIDR blocks allowed to access the GKE API server. Restrict in production."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "All networks"
    },
  ]
}

variable "resource_labels" {
  description = "Labels applied to the GKE cluster resource"
  type        = map(string)
  default     = {}
}
