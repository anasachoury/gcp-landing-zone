provider "google" {}

data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "landing-zone/bootstrap"
  }
}

data "terraform_remote_state" "org" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "landing-zone/01-org"
  }
}

locals {
  pipeline_sa        = data.terraform_remote_state.bootstrap.outputs.seed_sa_email
  logging_project_id = data.terraform_remote_state.org.outputs.logging_project_id
  security_email     = data.terraform_remote_state.org.outputs.group_emails["security-admins"]
}

# --- CMEK-ready key ----------------------------------------------------------
# A keyring and key in the central logging project. Point storage buckets,
# disks or logging at it to enforce CMEK where you need it.

resource "google_project_service" "kms" {
  project            = local.logging_project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

# The pipeline SA has org-level projectIamAdmin and grants itself KMS admin
# on the logging project for this apply.
resource "google_project_iam_member" "pipeline_kms_admin" {
  project = local.logging_project_id
  role    = "roles/cloudkms.admin"
  member  = "serviceAccount:${local.pipeline_sa}"
}

resource "google_kms_key_ring" "lz" {
  name     = "${var.prefix}-ring"
  project  = local.logging_project_id
  location = var.region

  # IAM grant and API enablement must land before the key ring is created.
  depends_on = [
    google_project_iam_member.pipeline_kms_admin,
    google_project_service.kms,
  ]
}

resource "google_kms_crypto_key" "cmek" {
  name            = "${var.prefix}-cmek"
  key_ring        = google_kms_key_ring.lz.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# --- Break-glass / sensitive-change alerting ----------------------------------
# Anything that changes organization IAM, org policies, or creates a service
# account key lands in the central log bucket (stage 01-org sink) and trips
# this alert within a minute. Email goes to the security-admins group.

locals {
  sensitive_filter = <<-EOT
    (resource.type="organization" AND (protoPayload.methodName:"SetIamPolicy" OR protoPayload.methodName:"OrgPolicy"))
    OR protoPayload.methodName:"CreateServiceAccountKey"
  EOT
}

resource "google_logging_metric" "sensitive_org_changes" {
  name    = "lz_sensitive_org_changes"
  project = local.logging_project_id
  filter  = local.sensitive_filter

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Sensitive organization changes (IAM, org policy, SA keys)"
  }
}

resource "google_monitoring_notification_channel" "security_email" {
  project      = local.logging_project_id
  display_name = "Security alerts"
  type         = "email"
  labels = {
    email_address = local.security_email
  }
}

resource "google_monitoring_alert_policy" "sensitive_org_changes" {
  project      = local.logging_project_id
  display_name = "Sensitive organization change"
  combiner     = "OR"

  conditions {
    display_name = "Any sensitive change in the last minute"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/lz_sensitive_org_changes\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.security_email.id]

  alert_strategy {
    auto_close = "604800s"
  }
}

# --- Example custom constraint ------------------------------------------------
# A template you can enforce from catalogs/org-policies.yaml by adding an
# entry with constraint "custom.allowedVmMachineFamilies". Not enforced until
# referenced by a policy — delete freely if you don't want the example.

resource "google_org_policy_custom_constraint" "vm_families" {
  name           = "custom.allowedVmMachineFamilies"
  parent         = "organizations/${var.org_id}"
  display_name   = "Restrict VM machine families"
  description    = "EXAMPLE: when enforced, only e2-standard-* machine types may be created."
  action_type    = "ALLOW"
  condition      = "resource.machineType.matches('e2-standard-[0-9]+')"
  method_types   = ["CREATE"]
  resource_types = ["compute.googleapis.com/Instance"]
}

# --- Optional VPC Service Controls (dry-run) ----------------------------------
# A dry-run perimeter: violations are logged, nothing is blocked. Inspect the
# logs for a few weeks, then decide what to enforce. Requires that no other
# access policy exists in the organization.

resource "google_access_context_manager_access_policy" "org" {
  count  = var.enable_vpc_sc ? 1 : 0
  parent = "organizations/${var.org_id}"
  title  = "${var.prefix} access policy"
}

resource "google_access_context_manager_service_perimeter" "dry_run" {
  count = var.enable_vpc_sc ? 1 : 0

  parent = google_access_context_manager_access_policy.org[0].name
  name   = "${google_access_context_manager_access_policy.org[0].name}/servicePerimeters/${var.prefix}-dry-run"
  title  = "${var.prefix} dry-run perimeter"

  use_explicit_dry_run_spec = true

  # Enforced configuration: nothing restricted yet.
  status {
    restricted_services = []
  }

  # Dry-run configuration: what WOULD be restricted, everywhere.
  spec {
    resources           = ["*"]
    restricted_services = var.vpc_sc_services
  }
}
