variable "subscription_id" {
  description = "The subscription that holds the platform resources and the budget."
  type        = string
}

variable "location" {
  description = "Region for platform resources."
  type        = string
  default     = "germanywestcentral"
}

variable "root_management_group_name" {
  description = "Management group created by scripts/bootstrap.sh and imported here."
  type        = string
  default     = "mg-swiftjob"
}

variable "log_daily_quota_gb" {
  description = "Hard daily ingestion cap of the central workspace. Beyond 5 GB a month every GB is billed."
  type        = number
  default     = 0.1
}

variable "budget_amount" {
  description = "Monthly safety-net budget for the whole subscription, in the billing currency (EUR)."
  type        = number
  default     = 25
}

variable "budget_start_date" {
  description = "First day of the budget period, RFC 3339. Must be the first of a month."
  type        = string
  default     = "2026-10-01T00:00:00Z"
}

variable "budget_alert_email" {
  description = "Recipient of budget alerts. Comes from a repository secret."
  type        = string
  sensitive   = true
}

variable "enforce_policies" {
  description = "false = DoNotEnforce (compliance is evaluated and reported, nothing is denied or deployed). Switched to true after the compliance review."
  type        = bool
  default     = true
}

variable "allowed_locations" {
  description = "Regions resource groups may use (only the old assignment for resource groups still reads this). Resource regions are set by allowed-locations-v2. westeurope stays because the cloud resume groups live there (ADR 3)."
  type        = list(string)
  default     = ["germanywestcentral", "global", "eastus2", "westeurope", "swedencentral", "northeurope"]
}

variable "enforce_phase2_policies" {
  description = "Enforcement of the policies added in phase 2. false = DoNotEnforce until the compliance review (ADR 3)."
  type        = bool
  default     = true
}

variable "static_site_locations" {
  description = "Static Web Apps are not offered in Germany; only this resource type may use these regions."
  type        = list(string)
  default     = ["eastus2", "westeurope"]
}

variable "compute_locations" {
  description = "Regions where the Container Apps compute types may run (ADR 8). Data stays in Germany West Central."
  type        = list(string)
  default     = ["swedencentral", "northeurope"]
}

variable "compute_types" {
  description = "Resource types of the Container Apps compute layer, allowed in compute_locations."
  type        = list(string)
  default     = ["Microsoft.App/managedEnvironments", "Microsoft.App/containerApps", "Microsoft.App/jobs"]
}

variable "network_cost_exempt_resource_groups" {
  description = "Resource groups where a VNet Container Apps environment, a Standard load balancer or a private endpoint is allowed: the throwaway network tests. The -infra group is created by Container Apps itself."
  type        = list(string)
  default     = ["rg-swiftjob-nettest", "rg-swiftjob-nettest-infra", "rg-cloudresume-nettest"]
}
