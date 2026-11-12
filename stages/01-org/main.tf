provider "google" {
  # Auth in CI: OIDC access token from google-github-actions/auth (exported
  # as GOOGLE_OAUTH_ACCESS_TOKEN). Auth locally: Application Default
  # Credentials via `gcloud auth application-default login`.
}

# The bootstrap stage outputs the pipeline identity.
data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "landing-zone/bootstrap"
  }
}

locals {
  folders  = yamldecode(file("${path.module}/../../catalogs/folders.yaml")).folders
  groups   = yamldecode(file("${path.module}/../../catalogs/groups.yaml")).groups
  bindings = yamldecode(file("${path.module}/../../catalogs/groups.yaml")).bindings
  policies = yamldecode(file("${path.module}/../../catalogs/org-policies.yaml")).policies

  group_emails = { for g in local.groups : g.id => g.email }
  pipeline_sa  = data.terraform_remote_state.bootstrap.outputs.seed_sa_email
  admin_email  = local.group_emails[var.admin_group_id]

  org_bindings = flatten([
    for b in local.bindings : [
      for role in b.roles : { group = b.group, role = role }
      if b.parent == "organization"
    ]
  ])

  folder_bindings = flatten([
    for b in local.bindings : [
      for role in b.roles : {
        folder = split(":", b.parent)[1]
        group  = b.group
        role   = role
      }
      if b.parent != "organization"
    ]
  ])
}

# --- Resource hierarchy ------------------------------------------------------

resource "google_folder" "folders" {
  for_each     = { for f in local.folders : f.name => f }
  display_name = each.value.display_name
  parent       = "organizations/${var.org_id}"
}

# --- Group IAM (never individual users) --------------------------------------

resource "google_organization_iam_member" "org_bindings" {
  for_each = { for b in local.org_bindings : "${b.group}|${b.role}" => b }
  org_id   = var.org_id
  role     = each.value.role
  member   = "group:${local.group_emails[each.value.group]}"
}

resource "google_folder_iam_member" "folder_bindings" {
  for_each = { for b in local.folder_bindings : "${b.folder}|${b.group}|${b.role}" => b }
  folder   = google_folder.folders[each.value.folder].name
  role     = each.value.role
  member   = "group:${local.group_emails[each.value.group]}"
}

# --- Central logging ---------------------------------------------------------

resource "google_project" "logging" {
  name            = "${var.prefix}-logging"
  project_id      = "${var.prefix}-logging"
  billing_account = var.billing_account
  folder_id       = google_folder.folders["common"].name
  deletion_policy = "PREVENT"
  labels = {
    managed_by = "terraform"
    stage      = "01-org"
  }
}

resource "google_project_service" "logging_services" {
  for_each = toset([
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "billingbudgets.googleapis.com",
    "essentialcontacts.googleapis.com",
  ])
  project            = google_project.logging.project_id
  service            = each.value
  disable_on_destroy = false
}

# The pipeline SA has org-level projectIamAdmin; it grants itself the
# project-scoped roles it needs to configure logging and monitoring here.
resource "google_project_iam_member" "pipeline_logging_admin" {
  project = google_project.logging.project_id
  role    = "roles/logging.admin"
  member  = "serviceAccount:${local.pipeline_sa}"
}

resource "google_project_iam_member" "pipeline_monitoring_editor" {
  project = google_project.logging.project_id
  role    = "roles/monitoring.editor"
  member  = "serviceAccount:${local.pipeline_sa}"
}

resource "google_logging_project_bucket_config" "audit" {
  project        = google_project.logging.project_id
  location       = var.log_location
  bucket_id      = "audit-logs"
  retention_days = var.audit_retention_days
  description    = "Organization-wide admin activity and system events"
}

resource "google_logging_organization_sink" "audit" {
  name             = "lz-org-audit-logs"
  description      = "Admin activity and system events from all projects"
  org_id           = var.org_id
  include_children = true
  destination      = "logging.googleapis.com/projects/${google_project.logging.number}/locations/${var.log_location}/buckets/${google_logging_project_bucket_config.audit.bucket_id}"
  filter           = "logName:\"cloudaudit.googleapis.com%2Factivity\" OR logName:\"cloudaudit.googleapis.com%2Fsystem_event\""
}

resource "google_project_iam_member" "audit_sink_writer" {
  project = google_project.logging.project_id
  role    = "roles/logging.bucketWriter"
  member  = google_logging_organization_sink.audit.writer_identity
}

# --- Essential contacts ------------------------------------------------------

resource "google_essential_contacts_contact" "org" {
  parent                              = "organizations/${var.org_id}"
  email                               = local.admin_email
  language_tag                        = "en"
  notification_category_subscriptions = ["ALL"]
}

# --- Org budget --------------------------------------------------------------

resource "google_monitoring_notification_channel" "budget_email" {
  project      = google_project.logging.project_id
  display_name = "Landing zone budget alerts"
  type         = "email"
  labels = {
    email_address = local.admin_email
  }
}

resource "google_billing_budget" "org" {
  count = var.org_budget_amount > 0 ? 1 : 0

  billing_account = var.billing_account
  display_name    = "${var.prefix}: organization monthly budget"

  amount {
    specified_amount {
      units         = tostring(var.org_budget_amount)
      currency_code = var.currency
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.budget_email.id]
  }
}

# --- Org policy library ------------------------------------------------------

locals {
  # One org-level rule per catalog entry, normalized to a single object
  # shape: exactly one of enforce / allow_all / deny_all / values is set.
  org_rules = {
    for p in local.policies : p.constraint => {
      enforce   = p.type == "boolean" ? tostring(p.enforce) : null
      allow_all = try(p.enforcement, null) == "allow" ? true : null
      deny_all  = try(p.enforcement, null) == "deny" ? true : null
      values = (try(p.allowed_values, null) != null || try(p.denied_values, null) != null) ? {
        allowed_values = try(p.allowed_values, null)
        denied_values  = try(p.denied_values, null)
      } : null
    }
  }

  # Folder-level exceptions: the constraint is lifted inside these folders.
  policy_exceptions = flatten([
    for p in local.policies : [
      for folder in try(p.exceptions, []) : {
        constraint = p.constraint
        folder     = folder
        boolean    = p.type == "boolean"
      }
    ]
  ])
}

resource "google_org_policy_policy" "org" {
  for_each = local.org_rules
  name     = "${var.org_id}/policies/${each.key}"
  parent   = "organizations/${var.org_id}"

  spec {
    rules {
      enforce   = each.value.enforce
      allow_all = each.value.allow_all
      deny_all  = each.value.deny_all

      dynamic "values" {
        for_each = each.value.values != null ? [each.value.values] : []
        content {
          allowed_values = values.value.allowed_values
          denied_values  = values.value.denied_values
        }
      }
    }
  }
}

resource "google_org_policy_policy" "folder_exception" {
  for_each = { for e in local.policy_exceptions : "${e.folder}|${e.constraint}" => e }
  name     = "${google_folder.folders[each.value.folder].folder_id}/policies/${each.value.constraint}"
  parent   = google_folder.folders[each.value.folder].name

  spec {
    rules {
      # Boolean constraints are turned off; list constraints unrestricted.
      enforce   = each.value.boolean ? "FALSE" : null
      allow_all = each.value.boolean ? null : true
    }
  }
}
