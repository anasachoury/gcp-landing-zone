provider "google" {}

# Folder placement comes from 01-org, shared VPC from 02-networking.
data "terraform_remote_state" "org" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "landing-zone/01-org"
  }
}

data "terraform_remote_state" "networking" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "landing-zone/02-networking"
  }
}

locals {
  catalog = yamldecode(file("${path.module}/../../catalogs/projects.yaml"))

  groups       = yamldecode(file("${path.module}/../../catalogs/groups.yaml")).groups
  group_emails = { for g in local.groups : g.id => g.email }

  env_codes = {
    development      = "dev"
    "non-production" = "nonprod"
    production       = "prod"
    sandbox          = "sbx"
  }

  # Every project gets these on top of its catalog services.
  base_services = [
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]

  projects = {
    for p in local.catalog.projects : "${p.app}-${p.environment}" => merge(p, {
      project_id = "${var.prefix}-${p.app}-${try(local.env_codes[p.environment], substr(p.environment, 0, 4))}"
    })
  }

  # project key → service pairs
  project_services = merge([
    for key, p in local.projects : {
      for svc in distinct(concat(local.base_services, p.services)) :
      "${key}#${svc}" => { project = key, service = svc }
    }
  ]...)

  # shared VPC subnet grants: project × subnet × principal
  subnet_members = merge([
    for key, p in local.projects : try(p.shared_vpc.attach, false) ? {
      for pair in setproduct(keys(data.terraform_remote_state.networking.outputs.subnet_self_links), try(p.shared_vpc.subnet_users, [])) :
      "${key}#${pair[0]}#${pair[1]}" => {
        subnet_key = pair[0]
        principal  = "group:${try(local.group_emails[pair[1]], pair[1])}"
      }
    } : {}
  ]...)

  service_accounts = merge([
    for key, p in local.projects : {
      for sa in try(p.service_accounts, []) :
      "${key}#${sa.id}" => {
        project      = key
        account_id   = "${p.app}-${sa.id}"
        display_name = try(sa.display_name, "${p.app} ${sa.id}")
        roles        = try(sa.roles, [])
      }
    }
  ]...)

  sa_roles = merge([
    for sa_key, sa in local.service_accounts : {
      for role in sa.roles :
      "${sa_key}#${role}" => { sa = sa_key, role = role }
    }
  ]...)

  # optional per-project group grants (catalog field `iam`)
  group_project_roles = merge([
    for key, p in local.projects : {
      for binding in try(p.iam, []) :
      "${key}#${binding.group}#${binding.role}" => {
        project = key
        email   = try(local.group_emails[binding.group], binding.group)
        role    = binding.role
      }
    }
  ]...)
}

# --- projects ----------------------------------------------------------------

resource "google_project" "projects" {
  for_each = local.projects

  name            = "${each.value.app}-${each.value.environment}"
  project_id      = each.value.project_id
  billing_account = var.billing_account
  folder_id       = data.terraform_remote_state.org.outputs.folder_names[each.value.folder]
  deletion_policy = "PREVENT"

  labels = merge(each.value.labels, {
    managed_by  = "terraform"
    environment = each.value.environment
  })
}

resource "google_project_service" "services" {
  for_each           = local.project_services
  project            = google_project.projects[each.value.project].project_id
  service            = each.value.service
  disable_on_destroy = false
}

# --- shared VPC --------------------------------------------------------------

resource "google_compute_shared_vpc_service_project" "attachments" {
  for_each = { for key, p in local.projects : key => p if try(p.shared_vpc.attach, false) }

  host_project    = data.terraform_remote_state.networking.outputs.host_project_id
  service_project = google_project.projects[each.key].project_id
}

resource "google_compute_subnetwork_iam_member" "subnet_users" {
  for_each = local.subnet_members

  project    = data.terraform_remote_state.networking.outputs.host_project_id
  region     = split("/", each.value.subnet_key)[0]
  subnetwork = split("/", each.value.subnet_key)[1]
  role       = "roles/compute.networkUser"
  member     = each.value.principal
}

# --- service accounts ----------------------------------------------------------

resource "google_service_account" "project_sas" {
  for_each = local.service_accounts

  project      = google_project.projects[each.value.project].project_id
  account_id   = each.value.account_id
  display_name = each.value.display_name
}

resource "google_project_iam_member" "sa_roles" {
  for_each = local.sa_roles

  project = google_project.projects[local.service_accounts[each.value.sa].project].project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.project_sas[each.value.sa].email}"
}

resource "google_project_iam_member" "group_roles" {
  for_each = local.group_project_roles

  project = google_project.projects[each.value.project].project_id
  role    = each.value.role
  member  = "group:${each.value.email}"
}

# --- budgets -------------------------------------------------------------------

resource "google_billing_budget" "project_budgets" {
  for_each = { for key, p in local.projects : key => p if try(p.budget.amount, 0) > 0 }

  billing_account = var.billing_account
  display_name    = "Budget ${google_project.projects[each.key].project_id}"

  budget_filter {
    projects = ["projects/${google_project.projects[each.key].number}"]
  }

  amount {
    specified_amount {
      units         = tostring(each.value.budget.amount)
      currency_code = var.currency
    }
  }

  # Threshold notifications (visible in the console and sent to billing
  # account admins). The organization-level budget in 01-org adds email
  # alerts to the landing zone admins group.
  dynamic "threshold_rules" {
    for_each = try(each.value.budget.thresholds, [])
    content {
      threshold_percent = threshold_rules.value
    }
  }
}
