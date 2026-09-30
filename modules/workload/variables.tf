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
  description = "Region of the Container Apps environment and everything that runs in it. Data resources (Key Vault, storage, identities, monitoring, kill switch) stay in location. See ADR 8."
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

variable "apps_enabled" {
  description = "false: infrastructure only. Apps, jobs and secret grants are created once the Key Vault secrets exist."
  type        = bool
  default     = false
}

variable "images" {
  description = "Image references by key, digests only."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for v in values(var.images) : can(regex("^ghcr\\.io/314159dd/[a-z0-9-]+@sha256:[0-9a-f]{64}$", v))])
    error_message = "images must be GHCR digests (ghcr.io/314159dd/<name>@sha256:<64 hex>)"
  }
}

variable "registry" {
  description = "Private registry and the Key Vault secret that holds its pull token. null for public images only."
  type        = object({ server = string, username = string, password_secret = string })
  default     = null
  validation {
    condition     = var.registry == null || contains(keys(var.secrets), var.registry.password_secret)
    error_message = "registry.password_secret must be one of the secrets"
  }
}

variable "secrets" {
  description = "Key Vault secrets by name (values are set outside Terraform) and the identities that may read each."
  type        = map(object({ readers = list(string) }))
  default     = {}
  validation {
    condition     = alltrue([for n, s in var.secrets : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", n)) && alltrue([for r in s.readers : contains(var.identities, r)])])
    error_message = "secret names are lowercase letters, digits and dashes; readers must be listed identities"
  }
}

variable "apps" {
  description = "Container apps by short name. image is a key of images or, for public images, a full reference."
  type = map(object({
    identity     = string
    image        = string
    port         = number
    cpu          = number
    memory       = string
    min_replicas = optional(number, 0)
    max_replicas = optional(number, 1)
    health_path  = optional(string)
    env          = optional(map(string), {})
    secret_env   = optional(map(string), {}) # ENV_NAME = Key Vault secret name
  }))
  default = {}
}

variable "jobs" {
  description = "Container Apps Jobs by short name. enabled = false creates a manual trigger (never runs on its own)."
  type = map(object({
    identity           = string
    image              = string
    command            = list(string)
    args               = optional(list(string), [])
    cpu                = number
    memory             = string
    cron               = optional(string)
    enabled            = optional(bool, false)
    timeout_seconds    = number
    retry_limit        = optional(number, 0)
    env                = optional(map(string), {})
    secret_env         = optional(map(string), {})
    missed_alert_hours = optional(number) # alert when no successful run within this many hours (1 to 48)
  }))
  default = {}
  validation {
    condition     = alltrue([for j in values(var.jobs) : j.missed_alert_hours == null || (j.missed_alert_hours >= 1 && j.missed_alert_hours <= 48 && floor(j.missed_alert_hours) == j.missed_alert_hours)])
    error_message = "missed_alert_hours must be a whole number between 1 and 48 (the alert window is rounded up to an allowed size and the query filters the exact hours)"
  }
}

variable "alerts" {
  description = "Operations alerts. api_app names the app whose errors and latency are watched."
  type = object({
    api_app           = optional(string)
    api_5xx_threshold = optional(number, 5)
    api_p95_ms        = optional(number, 3000)
  })
  default = {}
  validation {
    condition     = var.alerts.api_app == null || contains(keys(var.apps), var.alerts.api_app)
    error_message = "alerts.api_app must name one of the apps"
  }
}

variable "postgres" {
  description = "PostgreSQL flexible server with Entra ID sign-in only (ADR 9). null: no database in this environment."
  type = object({
    location       = string
    version        = optional(string, "17")
    sku_name       = optional(string, "B_Standard_B1ms")
    storage_mb     = optional(number, 32768)
    database       = string
    admin_identity = string
    owner_admin    = object({ object_id = string, principal_name = string, principal_type = optional(string, "User") })
    users          = list(string)
    # 80 % of the 35 user connections of B1ms (50 in total, 15 reserved by Azure)
    alert_connections = optional(number, 28)
  })
  default = null
  validation {
    condition     = var.postgres == null || try(var.postgres.sku_name, "") == "B_Standard_B1ms"
    error_message = "postgres.sku_name is B_Standard_B1ms (ADR 9, free-account grant); a larger SKU needs an ADR"
  }
  validation {
    condition     = var.postgres == null || try(var.postgres.storage_mb, 0) == 32768
    error_message = "postgres.storage_mb is 32768 (free-account grant)"
  }
  validation {
    condition     = var.postgres == null || (contains(var.identities, try(var.postgres.admin_identity, "")) && alltrue([for u in try(var.postgres.users, []) : contains(var.identities, u)]))
    error_message = "postgres.admin_identity and postgres.users must be listed identities"
  }
  validation {
    condition     = var.postgres == null || can(regex("^[a-z][a-z0-9_]{1,30}$", try(var.postgres.database, "")))
    error_message = "postgres.database is 2 to 31 lowercase letters, digits or underscores"
  }
}
