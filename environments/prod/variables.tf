# Values come from the private configuration repository (prod/terraform.tfvars) and from repository
# variables and secrets (subscription_id, alert_email). This file only declares them.
variable "subscription_id" {
  description = "Subscription of the environment."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "compute_location" {
  description = "Region of the Container Apps environment. Sweden Central like staging (ADR 8, ADR 12). The PostgreSQL region is postgres.location."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Resource group created by scripts/bootstrap.sh."
  type        = string
}

variable "identities" {
  description = "Workload identities."
  type        = list(string)
}

variable "blob_containers" {
  description = "Blob containers and their access."
  type        = map(object({ access = map(string) }))
  default     = {}
}

variable "telemetry_publishers" {
  description = "Identities that send telemetry."
  type        = list(string)
  default     = []
}

variable "budget_amount" {
  # owner decision pending (plan 05 Q6): production resource group budget, kill switch at 100 % actual. A value that
  # normal running exceeds stops swiftjob.de. The subscription safety net (platform layer, now 25) goes to 75 in a
  # separate platform change once the owner confirms Q6.
  description = "Monthly budget of the production resource group in EUR."
  type        = number
  default     = 50
}

variable "budget_start_date" {
  description = "Budget start, RFC 3339."
  type        = string
}

variable "alert_email" {
  description = "Alert recipient (repository secret)."
  type        = string
  sensitive   = true
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
}

variable "registry" {
  description = "Private registry and the Key Vault secret that holds its pull token. null for public images only."
  type        = object({ server = string, username = string, password_secret = string })
  default     = null
}

variable "secrets" {
  description = "Key Vault secrets by name (values are set outside Terraform) and the identities that may read each."
  type        = map(object({ readers = list(string) }))
  default     = {}
}

variable "apps" {
  description = "Container apps by short name."
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
    secret_env   = optional(map(string), {})
    # Host names bound with managed certificates once enable_custom_domains is true.
    custom_domains = optional(list(string), [])
  }))
  default = {}
}

variable "jobs" {
  description = "Container Apps Jobs by short name."
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
    missed_alert_hours = optional(number)
    idle_alert         = optional(object({ hours = number, counter = string }))
  }))
  default = {}
}

variable "alerts" {
  description = "Operations alerts. api_app names the app whose errors and latency are watched."
  type = object({
    api_app           = optional(string)
    api_5xx_threshold = optional(number, 5)
    api_p95_ms        = optional(number, 3000)
    # application alerts (modules/workload/app-alerts.tf); thresholds per environment
    log_alerts                   = optional(bool, true) # LLM, first-scan and ranking alerts read backend log lines
    llm_failures_per_hour        = optional(number, 5)  # per model, primary calls without fallback
    first_scan_failures_per_hour = optional(number, 1)  # alert above this many bad first scans per hour
    route_5xx_threshold          = optional(number, 2)  # 5xx on the key routes in 15 minutes
    route_p95_ms = optional(object({
      scan_events    = optional(number, 3000)
      titles_suggest = optional(number, 1500)
      onboarding     = optional(number, 10000)
    }), {})
  })
  default = {}
}

variable "postgres" {
  description = "PostgreSQL flexible server with Entra ID sign-in only (ADR 9); values from the configuration repository. null: no server."
  type = object({
    location = string
    version  = optional(string, "17")
    # owner decision pending (plan 05 Q4): B1ms on the free grant at launch; B_Standard_B2s if CPU alerts fire under real
    # users or before raising API replicas (more connections, about twice the price). The module accepts both.
    sku_name       = optional(string, "B_Standard_B1ms")
    storage_mb     = optional(number, 32768)
    database       = string
    admin_identity = string
    owner_admin    = object({ object_id = string, principal_name = string, principal_type = optional(string, "User") })
    users          = list(string)
    # 80 % of the 35 user connections of B1ms (50 in total, 15 reserved by Azure)
    alert_connections = optional(number, 28)
    # Extensions allow-listed for CREATE EXTENSION (azure.extensions); the migration job creates them
    extensions = optional(list(string), ["PG_TRGM"])
  })
  default = null
}

# ---- Owner decisions pending (plan 05). Each has the recommended default; the owner confirms or overrides in the
# private configuration. None of them is a secret.

variable "min_replicas_api" {
  # owner decision pending (plan 05 Q5, O4): 1 = always warm (about 20 to 30 EUR per month for api and web together),
  # 0 = scale to zero (first request after idle takes 20 to 54 s).
  description = "Minimum replicas of the api app. Overrides the value in apps.api."
  type        = number
  default     = 1
  validation {
    condition     = var.min_replicas_api >= 0 && var.min_replicas_api <= 1
    error_message = "min_replicas_api is 0 or 1 (one API replica at launch, connection budget of plan 05)"
  }
}

variable "min_replicas_web" {
  # owner decision pending (plan 05 Q5, O4): see min_replicas_api.
  description = "Minimum replicas of the web app. Overrides the value in apps.web."
  type        = number
  default     = 1
  validation {
    condition     = var.min_replicas_web >= 0 && var.min_replicas_web <= 2
    error_message = "min_replicas_web is 0, 1 or 2"
  }
}

variable "key_vault_purge_protection" {
  # decided as recommended (plan 05 Q14): yes. Irreversible on that vault; soft delete 7 days.
  description = "Purge protection on the production Key Vault."
  type        = bool
  default     = true
}

variable "enable_custom_domains" {
  description = "Create the custom domains and managed certificates of apps.*.custom_domains. false for the first apply: Azure issues a certificate only after the DNS records point at it (ADR 12, docs/prod-bootstrap.md)."
  type        = bool
  default     = false
}
