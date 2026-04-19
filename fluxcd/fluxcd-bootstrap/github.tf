# ===========================================================================
# GSA emails and project-specific values injected into FluxCD manifests.
# These files are committed to git by Terraform so that Flux picks up the
# correct Workload Identity annotations on first sync — no manual copy-paste.
# ===========================================================================

locals {
  eso_gsa_email = data.terraform_remote_state.scalr_admin.outputs.eso_gsa_email
  agents        = data.terraform_remote_state.scalr_admin.outputs.agents
}

resource "github_repository_file" "eso_serviceaccount" {
  repository          = var.github_repo
  branch              = var.github_branch
  file                = "fluxcd/infrastructure/external-secrets/serviceaccount.yaml"
  content             = templatefile("${path.module}/templates/eso-serviceaccount.yaml.tpl", {
    gsa_email = local.eso_gsa_email
  })
  commit_message      = "chore(flux-bootstrap): set ESO GSA email [skip ci]"
  overwrite_on_create = true
}

# One serviceaccount.yaml per agent, keyed by agent name (matches scalr-admin agents map).
# File path: fluxcd/infrastructure/scalr-agent-{name}/serviceaccount.yaml
resource "github_repository_file" "scalr_agent_serviceaccount" {
  for_each = local.agents

  repository          = var.github_repo
  branch              = var.github_branch
  file                = "fluxcd/infrastructure/scalr-agent-${each.key}/serviceaccount.yaml"
  content             = templatefile("${path.module}/templates/scalr-agent-serviceaccount.yaml.tpl", {
    gsa_email = each.value.scalr_agent_gsa_email
    namespace = each.value.namespace
    ksa       = each.value.ksa
  })
  commit_message      = "chore(flux-bootstrap): set Scalr Agent GSA email [${each.key}] [skip ci]"
  overwrite_on_create = true
}

resource "github_repository_file" "clustersecretstore" {
  repository          = var.github_repo
  branch              = var.github_branch
  file                = "fluxcd/infrastructure/external-secrets-config/clustersecretstore.yaml"
  content             = templatefile("${path.module}/templates/clustersecretstore.yaml.tpl", {
    gcp_project_id = var.gcp_project_id
  })
  commit_message      = "chore(flux-bootstrap): set ClusterSecretStore projectID [skip ci]"
  overwrite_on_create = true
}

# ===========================================================================
# Per-cluster Kustomization files — always created by Terraform for every
# cluster, ensuring a single consistent path regardless of cluster name.
# ===========================================================================

resource "github_repository_file" "cluster_kustomization" {
  repository          = var.github_repo
  branch              = var.github_branch
  file                = "fluxcd/clusters/${var.cluster_name}/kustomization.yaml"
  content             = file("${path.module}/templates/cluster-kustomization.yaml.tpl")
  commit_message      = "chore(flux-bootstrap): add cluster path for ${var.cluster_name} [skip ci]"
  overwrite_on_create = true
}

resource "github_repository_file" "cluster_infrastructure" {
  repository          = var.github_repo
  branch              = var.github_branch
  file                = "fluxcd/clusters/${var.cluster_name}/infrastructure.yaml"
  content             = templatefile("${path.module}/templates/cluster-infrastructure.yaml.tpl", {
    agents = local.agents
  })
  commit_message      = "chore(flux-bootstrap): add infrastructure Kustomizations for ${var.cluster_name} [skip ci]"
  overwrite_on_create = true
}
