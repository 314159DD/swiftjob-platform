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
