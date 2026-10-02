output "web_client_id" {
  value = azuread_application.web.client_id
}

output "api_client_id" {
  value = azuread_application.api.client_id
}

output "api_scope" {
  value = "api://${azuread_application.api.client_id}/api.access"
}

output "deleter_client_id" {
  value = azuread_application.deleter.client_id
}

output "admin_role_id" {
  value = var.admin_role_id
}
