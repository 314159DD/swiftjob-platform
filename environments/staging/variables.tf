# Values come from the private configuration repository (staging/terraform.tfvars) and from repository
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
  description = "Region of the Container Apps environment. Data stays in Germany West Central (ADR 8)."
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
  description = "Monthly budget in EUR."
  type        = number
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
  })
  default = {}
}

variable "postgres" {
  description = "PostgreSQL flexible server with Entra ID sign-in only (ADR 9); values from the configuration repository. null: no server."
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
    # Extensions allow-listed for CREATE EXTENSION (azure.extensions); the migration job creates them
    extensions = optional(list(string), ["PG_TRGM"])
  })
  default = null
}

variable "github_federations" {
  description = "GitHub Actions OIDC subjects by identity (Key Vault reader identities for workflows, e.g. the synthetic login test)."
  type        = map(list(string))
  default     = {}
}
