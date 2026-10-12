output "default_domain" {
  description = "Default domain of the staging environment."
  value       = module.workload.default_domain
}

output "key_vault_name" {
  description = "Staging Key Vault."
  value       = module.workload.key_vault_name
}

output "environment_static_ip" {
  description = "Target of the A record of an apex custom domain."
  value       = module.workload.environment_static_ip
}

output "custom_domain_verification_id" {
  description = "Value of the asuid TXT records for managed certificates (an identifier, not a credential)."
  value       = module.workload.custom_domain_verification_id
}

output "app_fqdns" {
  description = "Default host names of the apps (CNAME targets of subdomain custom domains)."
  value       = module.workload.app_fqdns
}

output "custom_domains" {
  description = "Custom host names declared per app (created only while enable_custom_domains is true)."
  value       = module.workload.custom_domains
}
