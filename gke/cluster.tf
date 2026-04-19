locals {
  workload_pool = "${var.gcp_project_id}.svc.id.goog"
}

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/gke-autopilot-cluster"
  version = "~> 44.0"

  project_id = var.gcp_project_id
  name       = var.cluster_name
  location   = var.gcp_region

  network    = module.vpc.network_name
  subnetwork = var.subnet_name

  ip_allocation_policy = {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  workload_identity_config = {
    workload_pool = local.workload_pool
  }

  private_cluster_config = {
    enable_private_endpoint = false
    enable_private_nodes    = true
    master_ipv4_cidr_block  = var.master_cidr
    master_global_access_config = {
      enabled = true
    }
  }

  master_authorized_networks_config = {
    cidr_blocks = var.master_authorized_networks
  }

  release_channel = {
    channel = "STABLE"
  }

  maintenance_policy = {
    daily_maintenance_window = {
      start_time = var.maintenance_window_start
    }
  }

  logging_config = {
    enable_components = [
      "SYSTEM_COMPONENTS",
    ]
  }

  monitoring_config = {
    enable_components = [
      "SYSTEM_COMPONENTS",
    ]
  }

  node_pool_auto_config = {
    node_kubelet_config = {
      insecure_kubelet_readonly_port_enabled = false
    }
  }

  master_auth = {
    client_certificate_config = {
      issue_client_certificate = false
    }
  }

  deletion_protection = false
  resource_labels     = var.resource_labels

  depends_on = [module.vpc, module.cloud_nat]
}
