# ===========================================================================
# Google provider
# ===========================================================================

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# ===========================================================================
# GKE cluster credentials
# ===========================================================================

data "google_client_config" "default" {}

data "google_container_cluster" "gke" {
  name     = var.gke_cluster_name
  location = var.gke_location
  project  = var.gcp_project_id
}

locals {
  gke_host = "https://${data.google_container_cluster.gke.endpoint}"
  gke_token = data.google_client_config.default.access_token
  gke_ca    = base64decode(data.google_container_cluster.gke.master_auth[0].cluster_ca_certificate)
}

# ===========================================================================
# scalr-admin remote state — source of GSA emails
# ===========================================================================

data "terraform_remote_state" "scalr_admin" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = var.scalr_admin_state_prefix
  }
}

# ===========================================================================
# GitHub PAT from Secret Manager
# ===========================================================================

data "google_secret_manager_secret_version" "github_pat" {
  secret  = var.github_pat_secret_name
  project = var.gcp_project_id
}

# ===========================================================================
# Kubernetes provider (required by the flux provider internally)
# ===========================================================================

provider "kubernetes" {
  host                   = local.gke_host
  token                  = local.gke_token
  cluster_ca_certificate = local.gke_ca
}

# ===========================================================================
# Flux provider
# ===========================================================================

provider "flux" {
  kubernetes = {
    host                   = local.gke_host
    token                  = local.gke_token
    cluster_ca_certificate = local.gke_ca
  }
  git = {
    url = "https://github.com/${var.github_org}/${var.github_repo}.git"
    http = {
      username = var.github_org
      password = data.google_secret_manager_secret_version.github_pat.secret_data
    }
  }
}

# ===========================================================================
# Flux Bootstrap
#
# Installs Flux controllers, creates flux-system namespace, GitHub auth
# secret, GitRepository and root Kustomization pointing to
# fluxcd/clusters/{cluster_name}. Commits gotk-components.yaml and
# gotk-sync.yaml into fluxcd/clusters/{cluster_name}/flux-system/.
#
# depends_on ensures SA files with correct GSA emails are in git before
# Flux performs its first sync.
# ===========================================================================

resource "flux_bootstrap_git" "this" {
  embedded_manifests = true
  path               = "fluxcd/clusters/${var.cluster_name}"
  version            = "v${var.flux_version}"
}
