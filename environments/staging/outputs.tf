output "default_domain" {
  description = "Default domain of the staging environment."
  value       = module.workload.default_domain
}

output "key_vault_name" {
  description = "Staging Key Vault."
  value       = module.workload.key_vault_name
}
