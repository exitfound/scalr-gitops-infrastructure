module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 18.0"

  project_id   = var.gcp_project_id
  network_name = var.network_name
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name           = var.subnet_name
      subnet_ip             = var.subnet_cidr
      subnet_region         = var.gcp_region
      subnet_private_access = true
      subnet_flow_logs      = true
      subnet_flow_logs_sampling = "0.5"
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
    },
  ]

  secondary_ranges = {
    (var.subnet_name) = [
      {
        range_name    = var.pods_range_name
        ip_cidr_range = var.pods_cidr
      },
      {
        range_name    = var.services_range_name
        ip_cidr_range = var.services_cidr
      },
    ]
  }
}

module "cloud_nat" {
  source  = "terraform-google-modules/cloud-router/google"
  version = "~> 9.0"

  name       = var.router_name
  region     = var.gcp_region
  project_id = var.gcp_project_id
  network    = module.vpc.network_name

  bgp = {
    asn = var.router_asn
  }

  nats = [
    {
      name                               = var.nat_name
      nat_ip_allocate_option             = "AUTO_ONLY"
      source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
      log_config = {
        enable = true
        filter = "ERRORS_ONLY"
      }
    },
  ]
}
