module "identity" {
  source        = "../../modules/external-identity"
  environment   = "staging"
  web_base_url  = var.web_base_url
  admin_role_id = var.admin_role_id
  scope_id      = var.scope_id
}
