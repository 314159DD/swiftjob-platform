module "identity" {
  source          = "../../modules/external-identity"
  environment     = "prod"
  web_base_url    = var.web_base_url
  extra_base_urls = var.extra_base_urls
  owner_client_id = var.tf_identity_client_id
  admin_role_id   = var.admin_role_id
  scope_id        = var.scope_id
}
