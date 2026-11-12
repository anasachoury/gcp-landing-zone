# Every stage declares the same core interface so CI and the Makefile can
# pass one uniform set of variables regardless of stage.

variable "org_id" {
  description = "Google Cloud organization id (numeric)."
  type        = string
}

variable "billing_account" {
  description = "Billing account id."
  type        = string
}

variable "prefix" {
  description = "Short prefix for resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 characters: lowercase letters, digits, hyphens; must start with a letter."
  }
}

variable "state_bucket" {
  description = "Terraform state bucket (used to read the bootstrap stage outputs)."
  type        = string
}

variable "admin_group_id" {
  description = "Group id (from catalogs/groups.yaml) that receives essential contacts and budget alerts."
  type        = string
  default     = "lz-admins"
}

variable "audit_retention_days" {
  description = "Retention for the central audit log bucket."
  type        = number
  default     = 365
}

variable "log_location" {
  description = "Location for the central log bucket: 'global' or a region like europe-west1."
  type        = string
  default     = "global"
}

variable "org_budget_amount" {
  description = "Monthly budget for the whole billing account (USD). 0 disables the budget."
  type        = number
  default     = 0
}

variable "currency" {
  description = "Currency code for budgets."
  type        = string
  default     = "USD"
}
