variable "environment" {
  description = "Environment name: staging, prod or nettest."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{3,10}$", var.environment))
    error_message = "environment must be 3 to 10 lowercase letters"
  }
}

variable "location" {
  description = "Region of every resource in the environment."
  type        = string
  default     = "germanywestcentral"
}

variable "compute_location" {
  description = "Region of the Container Apps environment and everything that runs in it. Data resources (Key Vault, storage, identities, monitoring, kill switch) stay in location. See ADR 6."
  type        = string
  default     = "germanywestcentral"
}

variable "resource_group_name" {
  description = "Existing resource group of the environment (created by scripts/bootstrap.sh)."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Central Log Analytics workspace (platform layer)."
  type        = string
}

variable "identities" {
  description = "One user-assigned managed identity per workload, by short name."
  type        = list(string)
  validation {
    condition     = alltrue([for i in var.identities : can(regex("^[a-z][a-z0-9-]{1,15}$", i))])
    error_message = "identity names are 2 to 16 lowercase letters, digits or dashes"
  }
}

variable "blob_containers" {
  description = "Private blob containers and which identity gets which data role on each."
  type        = map(object({ access = map(string) }))
  default     = {}
  validation {
    condition = alltrue(flatten([for c in values(var.blob_containers) : [
      for id, role in c.access : contains(var.identities, id) && contains(["Storage Blob Data Contributor", "Storage Blob Data Reader"], role)
    ]]))
    error_message = "blob access must name a listed identity and one of Storage Blob Data Contributor or Storage Blob Data Reader"
  }
}

variable "telemetry_publishers" {
  description = "Identities that send telemetry to Application Insights (Monitoring Metrics Publisher)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for i in var.telemetry_publishers : contains(var.identities, i)])
    error_message = "telemetry publishers must be listed identities"
  }
}

variable "budget_amount" {
  description = "Monthly budget of the resource group in EUR. At 100 % actual spend the kill switch stops the container apps."
  type        = number
}

variable "budget_start_date" {
  description = "First day of the budget period, RFC 3339, first of a month."
  type        = string
}

variable "alert_email" {
  description = "Recipient of budget and operations alerts."
  type        = string
  sensitive   = true
}

variable "name_salt" {
  description = "Extra input for the random-looking name suffix. Throwaway environments pass a run number so a soft-deleted Key Vault name is never reused."
  type        = string
  default     = ""
}
