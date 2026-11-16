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
  pipeline_sa            = data.terraform_remote_state.bootstrap.outputs.seed_sa_email
  logging_project_id     = data.terraform_remote_state.org.outputs.logging_project_id
  logging_project_number = data.terraform_remote_state.org.outputs.logging_project_number
  security_email         = data.terraform_remote_state.org.outputs.group_emails["security-admins"]
  production_folder      = data.terraform_remote_state.org.outputs.folder_ids["production"]

  # The Cloud Security Command Center service agent. Both the Pub/Sub feed and
  # the BigQuery export are written by it, and both need a grant.
  scc_service_agent = "service-org-${var.org_id}@security-center-api.iam.gserviceaccount.com"

  break_glass_accounts = data.terraform_remote_state.org.outputs.break_glass_accounts
  break_glass_regex = join("|", [
    for a in local.break_glass_accounts : replace(a, ".", "\\.")
  ])

  # Log-based metrics count what is stored in one bucket. The organization sink
  # from stage 01-org routes admin activity into this one, so the alerts below
  # see organization-level and project-level changes alike.
  audit_bucket_id = basename(data.terraform_remote_state.org.outputs.log_buckets["audit-logs"])
}

# --- CMEK-ready key ----------------------------------------------------------
# A keyring and key in the central logging project. Point storage buckets,
# disks or logging at it to enforce CMEK where you need it. The org policy
# library (catalogs/org-policies.yaml) is what actually requires CMEK for the
# services listed there.

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

# --- Security Command Center -------------------------------------------------
# SCC Standard is on for every organization; the findings feed, the notification
# config and the export below are what turn it into something a team can act on.
# Premium tier is a billing action (see docs/day-2.md) — these resources work
# with either tier, they just see fewer detectors on Standard.

resource "google_project_service" "scc" {
  count = var.enable_scc ? 1 : 0

  project            = local.logging_project_id
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

# Findings on a Pub/Sub topic: the hook for a pager, a ticketing system or a
# SOAR playbook. Filter is high and critical only — the console keeps the rest.
resource "google_pubsub_topic" "scc_findings" {
  count = var.enable_scc ? 1 : 0

  project = local.logging_project_id
  name    = "${var.prefix}-scc-findings"

  labels = {
    managed_by = "terraform"
    stage      = "03-security"
  }

  depends_on = [google_project_service.scc]
}

resource "google_pubsub_topic_iam_member" "scc_publisher" {
  count = var.enable_scc ? 1 : 0

  project = local.logging_project_id
  topic   = google_pubsub_topic.scc_findings[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.scc_service_agent}"
}

resource "google_scc_v2_organization_notification_config" "findings" {
  count = var.enable_scc ? 1 : 0

  organization = var.org_id
  config_id    = "${var.prefix}-high-severity"
  location     = "global"
  description  = "High and critical findings, streaming to Pub/Sub"
  pubsub_topic = google_pubsub_topic.scc_findings[0].id

  streaming_config {
    filter = "state=\"ACTIVE\" AND (severity=\"HIGH\" OR severity=\"CRITICAL\") AND NOT mute=\"MUTED\""
  }
}

# Findings in BigQuery: the "show me every open critical finding by resource
# over the last 90 days" question, and the history the console does not keep.
resource "google_bigquery_dataset" "scc_findings" {
  count = var.enable_scc ? 1 : 0

  project     = local.logging_project_id
  dataset_id  = "${replace(var.prefix, "-", "_")}_scc_findings"
  location    = var.region
  description = "Cloud Security Command Center findings, continuously exported"

  labels = {
    managed_by = "terraform"
    stage      = "03-security"
  }
}

resource "google_bigquery_dataset_iam_member" "scc_export_writer" {
  count = var.enable_scc ? 1 : 0

  project    = google_bigquery_dataset.scc_findings[0].project
  dataset_id = google_bigquery_dataset.scc_findings[0].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${local.scc_service_agent}"
}

resource "google_scc_v2_organization_scc_big_query_exports" "findings" {
  count = var.enable_scc ? 1 : 0

  organization        = var.org_id
  big_query_export_id = "${var.prefix}-findings"
  location            = "global"
  description         = "Continuous export of SCC findings"
  dataset             = "projects/${local.logging_project_id}/datasets/${google_bigquery_dataset.scc_findings[0].dataset_id}"
  filter              = "state=\"ACTIVE\""

  depends_on = [google_bigquery_dataset_iam_member.scc_export_writer]
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

  # Log-based metrics count what is stored in one bucket. The organization
  # sink from stage 01-org routes admin activity there, so the metric sees
  # org-level and project-level changes alike.
  bucket_name = local.audit_bucket_id

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

# Any activity at all by a break-glass account. The accounts hold no standing
# role, so the only thing they can do is what an incident responder adds to the
# group — and this fires the moment they use it, before they touch anything.
resource "google_logging_metric" "break_glass_activity" {
  name        = "lz_break_glass_activity"
  project     = local.logging_project_id
  bucket_name = local.audit_bucket_id
  filter      = "protoPayload.authenticationInfo.principalEmail=~\"^(${local.break_glass_regex})$\""

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Activity by a break-glass account"
  }
}

resource "google_monitoring_alert_policy" "break_glass_activity" {
  project      = local.logging_project_id
  display_name = "Break-glass account in use"
  combiner     = "OR"

  conditions {
    display_name = "Break-glass principal made an API call"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/lz_break_glass_activity\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.security_email.id]

  alert_strategy {
    auto_close = "86400s"
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

# --- VPC Service Controls -----------------------------------------------------
# A perimeter around the production folder. dry_run logs what WOULD have been
# blocked and blocks nothing; enforce actually blocks. The path is
# dry_run → read the violations for a couple of weeks → enforce, which is why
# vpc_sc_mode exists as a switch rather than a comment.
#
# Requires that no other access policy exists in the organization.

resource "google_access_context_manager_access_policy" "org" {
  count  = var.enable_vpc_sc ? 1 : 0
  parent = "organizations/${var.org_id}"
  title  = "${var.prefix} access policy"
}

resource "google_access_context_manager_access_policy_iam_member" "security_admins" {
  count = var.enable_vpc_sc ? 1 : 0

  name   = google_access_context_manager_access_policy.org[0].name
  role   = "roles/accesscontextmanager.policyAdmin"
  member = "group:${local.security_email}"
}

# An access level is the "from where" half of every ingress rule. Corporate
# egress ranges only — a laptop on a home network is not inside the perimeter
# even with valid credentials.
resource "google_access_context_manager_access_level" "corp" {
  count = var.enable_vpc_sc ? 1 : 0

  parent = local.access_policy_name
  name   = local.corp_access_level_name
  title  = "Corporate network"
  basic {
    combining_function = "OR"
    conditions {
      ip_subnetworks = var.vpc_sc_trusted_cidrs
    }
  }
}

locals {
  # `one(...[*])` rather than `[0]` so these evaluate to null — instead of
  # failing the plan — when VPC-SC is switched off.
  access_policy_name     = one(google_access_context_manager_access_policy.org[*].name)
  corp_access_level_name = local.access_policy_name == null ? null : "${local.access_policy_name}/accessLevels/${var.prefix}-corp-network"

  # Everything the perimeter protects: the whole production folder, so new
  # factory projects are inside it the moment they are created.
  perimeter_resources = ["folders/${local.production_folder}"]

  # One ingress rule: identities on the corporate network may reach the
  # services listed in vpc_sc_services.
  perimeter_ingress = {
    access_level = local.corp_access_level_name
  }

  # One egress rule: everything inside may still write to the logging project,
  # otherwise the audit trail dies the moment the perimeter is enforced.
  perimeter_egress = {
    resources = ["projects/${local.logging_project_number}"]
  }
}

resource "google_access_context_manager_service_perimeter" "production" {
  count = var.enable_vpc_sc ? 1 : 0

  parent = local.access_policy_name
  name   = "${local.access_policy_name}/servicePerimeters/${var.prefix}-production"
  title  = "${var.prefix} production perimeter"

  # In dry-run mode `spec` holds the proposed config and `status` enforces
  # nothing. In enforce mode it is the other way round.
  use_explicit_dry_run_spec = var.vpc_sc_mode == "dry_run"

  status {
    resources           = var.vpc_sc_mode == "enforce" ? local.perimeter_resources : []
    restricted_services = var.vpc_sc_mode == "enforce" ? var.vpc_sc_services : []
    access_levels       = var.vpc_sc_mode == "enforce" ? [local.corp_access_level_name] : []

    dynamic "ingress_policies" {
      for_each = var.vpc_sc_mode == "enforce" ? [local.perimeter_ingress] : []
      content {
        ingress_from {
          sources {
            access_level = ingress_policies.value.access_level
          }
        }
        ingress_to {
          resources = ["*"]
          operations {
            service_name = "*"
            method_selectors {
              method = "*"
            }
          }
        }
      }
    }

    dynamic "egress_policies" {
      for_each = var.vpc_sc_mode == "enforce" ? [local.perimeter_egress] : []
      content {
        egress_from {
          identity_type = "ANY_IDENTITY"
        }
        egress_to {
          resources = egress_policies.value.resources
          operations {
            service_name = "*"
            method_selectors {
              method = "*"
            }
          }
        }
      }
    }

    vpc_accessible_services {
      enable_restriction = true
      allowed_services   = var.vpc_sc_services
    }
  }

  dynamic "spec" {
    for_each = var.vpc_sc_mode == "dry_run" ? [1] : []
    content {
      resources           = local.perimeter_resources
      restricted_services = var.vpc_sc_services
      access_levels       = [local.corp_access_level_name]

      dynamic "ingress_policies" {
        for_each = [local.perimeter_ingress]
        content {
          ingress_from {
            sources {
              access_level = ingress_policies.value.access_level
            }
          }
          ingress_to {
            resources = ["*"]
            operations {
              service_name = "*"
              method_selectors {
                method = "*"
              }
            }
          }
        }
      }

      dynamic "egress_policies" {
        for_each = [local.perimeter_egress]
        content {
          egress_from {
            identity_type = "ANY_IDENTITY"
          }
          egress_to {
            resources = egress_policies.value.resources
            operations {
              service_name = "*"
              method_selectors {
                method = "*"
              }
            }
          }
        }
      }

      vpc_accessible_services {
        enable_restriction = true
        allowed_services   = var.vpc_sc_services
      }
    }
  }

  depends_on = [google_access_context_manager_access_level.corp]
}
