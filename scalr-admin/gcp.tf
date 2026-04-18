module "eso" {
  source    = "./modules/eso"
  project   = var.gcp_project_id
  namespace = var.eso_namespace
  ksa       = var.eso_ksa
}
