# Every stage declares the same core interface so CI and the Makefile can
# pass one uniform set of variables regardless of stage. billing_account is
# declared for uniformity; this stage creates no billable resources.

variable "org_id" {
  description = "Google Cloud organization id (numeric)."
  type        = string
}

# Declared but unused on purpose: every stage exposes the same core
# interface so CI and the Makefile pass one uniform set of variables.
# tflint-ignore: terraform_unused_declarations
variable "billing_account" {
  description = "Billing account id (unused by this stage; part of the uniform stage interface)."
  type        = string
  default     = ""
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
  description = "Terraform state bucket (used to read the bootstrap and 01-org outputs)."
  type        = string
}

variable "region" {
  description = "Location for the KMS key ring and the SCC findings dataset."
  type        = string
  default     = "europe-west1"
}

variable "enable_scc" {
  description = "Create the Security Command Center findings feed (Pub/Sub), the BigQuery export and their IAM grants. Requires SCC to be enrolled on the organization."
  type        = bool
  default     = true
}

variable "enable_vpc_sc" {
  description = "EXPERIMENTAL: create an access policy and a VPC Service Controls perimeter around the production folder. Only one access policy can exist per organization — verify in the console first."
  type        = bool
  default     = false
}

variable "vpc_sc_mode" {
  description = "\"dry_run\" logs what the perimeter would block; \"enforce\" blocks it. Run dry-run first and read the violations."
  type        = string
  default     = "dry_run"

  validation {
    condition     = contains(["dry_run", "enforce"], var.vpc_sc_mode)
    error_message = "vpc_sc_mode must be \"dry_run\" or \"enforce\"."
  }
}

variable "vpc_sc_services" {
  description = "Services inside the VPC-SC perimeter (also the services reachable from the corporate network)."
  type        = list(string)
  default = [
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "logging.googleapis.com",
  ]
}

variable "vpc_sc_trusted_cidrs" {
  description = "EDIT: corporate egress ranges allowed into the perimeter. The default is TEST-NET-2 and matches nothing real."
  type        = list(string)
  default     = ["198.51.100.0/24"]
}
