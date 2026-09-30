output "default_domain" {
  description = "Default domain of the Container Apps environment; app URLs are https://<app>.<domain>."
  value       = azurerm_container_app_environment.this.default_domain
}

output "environment_id" {
  description = "Container Apps environment ID."
  value       = azurerm_container_app_environment.this.id
}

output "identity_ids" {
  description = "Identity resource IDs by workload."
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.id }
}

output "identity_client_ids" {
  description = "Identity client IDs by workload (AZURE_CLIENT_ID in the containers)."
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.client_id }
}

output "identity_principal_ids" {
  description = "Identity principal (object) IDs by workload."
  value       = { for k, v in azurerm_user_assigned_identity.this : k => v.principal_id }
}

output "key_vault_id" {
  description = "Key Vault ID."
  value       = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = azurerm_key_vault.this.vault_uri
}

output "key_vault_name" {
  description = "Key Vault name (for scripts/load-secrets.sh in the configuration repository)."
  value       = azurerm_key_vault.this.name
}

output "storage_account_name" {
  description = "Storage account name."
  value       = azurerm_storage_account.this.name
}

output "blob_endpoint" {
  description = "Blob endpoint."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "application_insights_id" {
  description = "Application Insights ID."
  value       = azurerm_application_insights.this.id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string (no key use: local authentication is off)."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "email_action_group_id" {
  description = "Action group for operations alerts."
  value       = azurerm_monitor_action_group.email.id
}
