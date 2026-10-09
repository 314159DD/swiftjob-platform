output "default_domain" {
  description = "Default domain of the production environment."
  value       = module.workload.default_domain
}

output "key_vault_name" {
  description = "Production Key Vault."
  value       = module.workload.key_vault_name
}

output "environment_static_ip" {
  description = "Target of the A record of the apex domain (plan 05 cutover)."
  value       = module.workload.environment_static_ip
}

output "custom_domain_verification_id" {
  description = "Value of the asuid TXT records for managed certificates (an identifier, not a credential)."
  value       = module.workload.custom_domain_verification_id
}

output "app_fqdns" {
  description = "Default host names of the apps (CNAME targets of the subdomains)."
  value       = module.workload.app_fqdns
}
