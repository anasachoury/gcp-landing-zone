variable "org_id" {
  description = "Google Cloud organization id (numeric)."
  type        = string
}

variable "billing_account" {
  description = "Billing account id (e.g. 01ABCD-123456-7890EF)."
  type        = string
}

variable "prefix" {
  description = "Short prefix for resource names (project ids, service accounts)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 characters: lowercase letters, digits, hyphens; must start with a letter."
  }
}

variable "bootstrap_project_id" {
  description = "Project hosting bootstrap resources (created by bootstrap.sh)."
  type        = string
}

variable "state_bucket" {
  description = "GCS bucket for Terraform state (created by bootstrap.sh)."
  type        = string
}

variable "github_owner" {
  description = "GitHub owner (user or organization) of the pipeline repository."
  type        = string
}

variable "github_repo" {
  description = "Name of the repository that runs the landing zone pipelines."
  type        = string
}
