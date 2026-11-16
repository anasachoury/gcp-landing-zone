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
  audit    = yamldecode(file("${path.module}/../../catalogs/audit-logs.yaml"))
  tags     = yamldecode(file("${path.module}/../../catalogs/tags.yaml"))

  group_emails = { for g in local.groups : g.id => g.email }
  pipeline_sa  = data.terraform_remote_state.bootstrap.outputs.seed_sa_email
  admin_email  = local.group_emails[var.admin_group_id]

  # ${org_id} and ${prefix} in catalog values are expanded here. The doubled
  # $ stops Terraform interpolating them while parsing this file, so the
  # catalog can say "under:organizations/${org_id}" and mean it.
  policies = [
    for p in yamldecode(file("${path.module}/../../catalogs/org-policies.yaml")).policies : merge(p, {
      allowed_values = try([
        for v in p.allowed_values : replace(replace(v, "$${org_id}", var.org_id), "$${prefix}", var.prefix)
      ], null)
      denied_values = try([
        for v in p.denied_values : replace(replace(v, "$${org_id}", var.org_id), "$${prefix}", var.prefix)
      ], null)
    })
  ]

  # Policies without a `folder:` key are organization-scoped; those with one
  # are rendered at that folder instead. `policy_spec` below carries the
  # distinction through to the two resources.
  org_policies = [for p in local.policies : p if try(p.folder, null) == null]

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

  # One normalized shape for both policy scopes: exactly one of
  # enforce / allow_all / deny_all / values is set.
  policy_spec = {
    for p in local.policies : "${try(p.folder, "org")}|${p.constraint}" => {
      constraint = p.constraint
      folder     = try(p.folder, null)
      inherit    = try(p.inherit_from_parent, null)
      enforce    = p.type == "boolean" ? tostring(p.enforce) : null
      allow_all  = try(p.enforcement, null) == "allow" ? "true" : null
      deny_all   = try(p.enforcement, null) == "deny" ? "true" : null
      allowed    = try(p.allowed_values, null)
      denied     = try(p.denied_values, null)
      has_values = try(p.allowed_values, null) != null || try(p.denied_values, null) != null
    }
  }

  # Folder-level exceptions: the constraint is lifted inside these folders.
  policy_exceptions = flatten([
    for p in local.org_policies : [
      for folder in try(p.exceptions, []) : {
        constraint = p.constraint
        folder     = folder
        boolean    = p.type == "boolean"
      }
    ]
  ])

  buckets        = { for b in local.audit.buckets : b.id => b }
  export_bq      = try(local.audit.exports.bigquery.enabled, false)
  export_pubsub  = try(local.audit.exports.pubsub.enabled, false)
  audit_services = { for s in try(local.audit.audit_config.services, []) : s.service => s }
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
    "bigquery.googleapis.com",
    "pubsub.googleapis.com",
  ])
  project            = google_project.logging.project_id
  service            = each.value
  disable_on_destroy = false
}

# The pipeline SA has org-level projectIamAdmin; it grants itself the
# project-scoped roles it needs to configure logging, exports and monitoring.
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

resource "google_project_iam_member" "pipeline_bigquery_admin" {
  project = google_project.logging.project_id
  role    = "roles/bigquery.admin"
  member  = "serviceAccount:${local.pipeline_sa}"
}

# Stage 03-security creates the SCC findings topic and dataset in this
# project, so both grants are unconditional rather than tied to the audit
# export switches in the catalog.
resource "google_project_iam_member" "pipeline_pubsub_admin" {
  project = google_project.logging.project_id
  role    = "roles/pubsub.admin"
  member  = "serviceAccount:${local.pipeline_sa}"
}

# --- Audit log configuration (Data Access) -----------------------------------
# Admin Activity and System Event logs are recorded for free and cannot be
# turned off. Data Access logs are per-service opt-in and are what makes
# "who read this bucket" answerable. Set once per organization.

resource "google_organization_iam_audit_config" "all_services" {
  org_id  = var.org_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = local.audit.audit_config.all_services.log_types
    content {
      log_type = audit_log_config.value
    }
  }
}

# Per-service overrides. These run after the allServices entry so the first
# apply does not race two writers against the same IAM policy.
resource "google_organization_iam_audit_config" "services" {
  for_each = local.audit_services

  org_id  = var.org_id
  service = each.key

  dynamic "audit_log_config" {
    for_each = each.value.log_types
    content {
      log_type         = audit_log_config.value
      exempted_members = try(each.value.exempted_members, null)
    }
  }

  depends_on = [google_organization_iam_audit_config.all_services]
}

# --- Log buckets and sinks ---------------------------------------------------
# One bucket and one organization-wide sink per entry in
# catalogs/audit-logs.yaml: admin activity, data access, network, DNS.

resource "google_logging_project_bucket_config" "buckets" {
  for_each = local.buckets

  project        = google_project.logging.project_id
  location       = var.log_location
  bucket_id      = each.value.id
  retention_days = each.value.retention_days
  description    = each.value.description
}

resource "google_logging_organization_sink" "buckets" {
  for_each = local.buckets

  name             = "lz-org-${each.value.id}"
  description      = each.value.description
  org_id           = var.org_id
  include_children = true
  filter           = each.value.filter
  destination      = "logging.googleapis.com/projects/${google_project.logging.number}/locations/${var.log_location}/buckets/${each.value.id}"
}

resource "google_project_iam_member" "sink_writers" {
  for_each = local.buckets

  project = google_project.logging.project_id
  role    = "roles/logging.bucketWriter"
  member  = google_logging_organization_sink.buckets[each.key].writer_identity
}

# --- Audit export: BigQuery ------------------------------------------------
# A queryable, long-lived copy of the audit trail that outlives the log
# buckets and does not depend on the console.

resource "google_bigquery_dataset" "audit_export" {
  count = local.export_bq ? 1 : 0

  project     = google_project.logging.project_id
  dataset_id  = local.audit.exports.bigquery.dataset
  location    = local.audit.exports.bigquery.location
  description = local.audit.exports.bigquery.description
  # 0 / unset means partitions never expire.
  default_partition_expiration_ms = (
    try(local.audit.exports.bigquery.retention_days, 0) > 0
    ? local.audit.exports.bigquery.retention_days * 86400000
    : null
  )

  labels = {
    managed_by = "terraform"
    stage      = "01-org"
  }

  depends_on = [google_project_iam_member.pipeline_bigquery_admin]
}

resource "google_logging_organization_sink" "bigquery" {
  count = local.export_bq ? 1 : 0

  name             = "lz-org-bigquery"
  description      = "Audit logs exported to BigQuery"
  org_id           = var.org_id
  include_children = true
  filter           = local.audit.exports.bigquery.filter
  destination      = "bigquery.googleapis.com/projects/${google_project.logging.project_id}/datasets/${google_bigquery_dataset.audit_export[0].dataset_id}"

  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "audit_sink_writer" {
  count = local.export_bq ? 1 : 0

  project    = google_bigquery_dataset.audit_export[0].project
  dataset_id = google_bigquery_dataset.audit_export[0].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_organization_sink.bigquery[0].writer_identity
}

# --- Audit export: Pub/Sub --------------------------------------------------
# Streaming feed for a SIEM. The subscription belongs to the consumer, so none
# is created here.

resource "google_pubsub_topic" "audit_feed" {
  count = local.export_pubsub ? 1 : 0

  project = google_project.logging.project_id
  name    = local.audit.exports.pubsub.topic

  labels = {
    managed_by = "terraform"
    stage      = "01-org"
  }

  depends_on = [google_project_iam_member.pipeline_pubsub_admin]
}

resource "google_logging_organization_sink" "pubsub" {
  count = local.export_pubsub ? 1 : 0

  name             = "lz-org-pubsub"
  description      = "Audit logs streamed to Pub/Sub"
  org_id           = var.org_id
  include_children = true
  filter           = local.audit.exports.pubsub.filter
  destination      = "pubsub.googleapis.com/projects/${google_project.logging.project_id}/topics/${google_pubsub_topic.audit_feed[0].name}"
}

resource "google_pubsub_topic_iam_member" "audit_sink_publisher" {
  count = local.export_pubsub ? 1 : 0

  project = google_project.logging.project_id
  topic   = google_pubsub_topic.audit_feed[0].name
  role    = "roles/pubsub.publisher"
  member  = google_logging_organization_sink.pubsub[0].writer_identity
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

resource "google_org_policy_policy" "org" {
  for_each = { for k, v in local.policy_spec : k => v if v.folder == null }

  name   = "${var.org_id}/policies/${each.value.constraint}"
  parent = "organizations/${var.org_id}"

  spec {
    inherit_from_parent = each.value.inherit

    rules {
      enforce   = each.value.enforce
      allow_all = each.value.allow_all
      deny_all  = each.value.deny_all

      dynamic "values" {
        for_each = each.value.has_values ? [1] : []
        content {
          allowed_values = each.value.allowed
          denied_values  = each.value.denied
        }
      }
    }
  }
}

# Policies scoped to one folder (catalog `folder:` key) — for constraints that
# belong in one part of the hierarchy rather than everywhere.
resource "google_org_policy_policy" "folder_scope" {
  for_each = { for k, v in local.policy_spec : k => v if v.folder != null }

  name   = "${google_folder.folders[each.value.folder].folder_id}/policies/${each.value.constraint}"
  parent = google_folder.folders[each.value.folder].name

  spec {
    inherit_from_parent = each.value.inherit

    rules {
      enforce   = each.value.enforce
      allow_all = each.value.allow_all
      deny_all  = each.value.deny_all

      dynamic "values" {
        for_each = each.value.has_values ? [1] : []
        content {
          allowed_values = each.value.allowed
          denied_values  = each.value.denied
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
      enforce   = each.value.boolean ? "false" : null
      allow_all = each.value.boolean ? null : "true"
    }
  }
}

# --- Resource tags -----------------------------------------------------------
# Org-defined keys and values. Unlike labels these can be referenced from org
# policy and IAM conditions, and only the tag administrator can redefine them.

resource "google_tags_tag_key" "keys" {
  for_each = { for k in local.tags.keys : k.short_name => k }

  parent      = "organizations/${var.org_id}"
  short_name  = each.value.short_name
  description = try(each.value.description, null)
}

resource "google_tags_tag_value" "values" {
  for_each = merge([
    for k in local.tags.keys : {
      for v in k.values : "${k.short_name}/${v}" => { key = k.short_name, value = v }
    }
  ]...)

  parent      = google_tags_tag_key.keys[each.value.key].id
  short_name  = each.value.value
  description = "${each.value.key} = ${each.value.value}"
}

# --- State moves -------------------------------------------------------------
# The log bucket, its sink and the writer grant used to be single resources;
# they are now catalog-driven collections. These keep the first apply after
# the upgrade from replacing the audit trail.

moved {
  from = google_logging_project_bucket_config.audit
  to   = google_logging_project_bucket_config.buckets["audit-logs"]
}

moved {
  from = google_logging_organization_sink.audit
  to   = google_logging_organization_sink.buckets["audit-logs"]
}

moved {
  from = google_project_iam_member.audit_sink_writer
  to   = google_project_iam_member.sink_writers["audit-logs"]
}
