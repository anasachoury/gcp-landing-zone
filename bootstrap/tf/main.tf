provider "google" {
  # Credentials come from the caller: Application Default Credentials when
  # run from bootstrap.sh (org admin), never from a key file.
}

locals {
  # Org-level roles for the pipeline service account. Each entry is the
  # minimum one or more stages need (see bootstrap/README.md for details):
  #
  #   projectCreator                     10-factory: create projects
  #   folderAdmin                        01-org: create folders, grant folder IAM
  #   organizationViewer                 01-org: read the organization
  #   projectIamAdmin                    01/03/10: grant IAM inside created projects
  #   orgpolicy.policyAdmin              01-org: apply the org policy library
  #   compute.xpnAdmin                   02/10: shared VPC host and attachments
  #   logging.configWriter               01-org: organization-level log sinks
  #   essentialcontacts.admin            01-org: org-level essential contacts
  #   serviceusage.serviceUsageAdmin     02/10: enable APIs on created projects
  #   accesscontextmanager.policyAdmin   03-security: optional VPC-SC perimeter
  pipeline_org_roles = [
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.folderAdmin",
    "roles/resourcemanager.organizationViewer",
    "roles/resourcemanager.projectIamAdmin",
    "roles/orgpolicy.policyAdmin",
    "roles/compute.xpnAdmin",
    "roles/logging.configWriter",
    "roles/essentialcontacts.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/accesscontextmanager.policyAdmin",
  ]
}

# The pipeline identity. No keys are ever created for it (the org policy
# library disables SA key creation org-wide anyway): it is used exclusively
# through GitHub OIDC federation below.
resource "google_service_account" "pipeline" {
  project      = var.bootstrap_project_id
  account_id   = "${var.prefix}-pipeline"
  display_name = "Landing zone pipeline (GitHub Actions OIDC)"
}

resource "google_organization_iam_member" "pipeline" {
  for_each = toset(local.pipeline_org_roles)
  org_id   = var.org_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.pipeline.email}"
}

# billing.user: attach projects to the billing account.
resource "google_billing_account_iam_member" "pipeline_user" {
  billing_account_id = var.billing_account
  role               = "roles/billing.user"
  member             = "serviceAccount:${google_service_account.pipeline.email}"
}

# billing.admin: create the organization and per-project budgets.
# Deliberately broad: scoped to the billing account only, and the pipeline
# can already create projects on it. Reduce it once budgets are stable.
resource "google_billing_account_iam_member" "pipeline_admin" {
  billing_account_id = var.billing_account
  role               = "roles/billing.admin"
  member             = "serviceAccount:${google_service_account.pipeline.email}"
}

# --- GitHub OIDC federation (Workload Identity Federation) ---
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.bootstrap_project_id
  workload_identity_pool_id = "${var.prefix}-github-pool"
  display_name              = "GitHub Actions"
  description               = "Landing zone pipelines for ${var.github_owner}/${var.github_repo}"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.bootstrap_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"
  description                        = "Trusts GitHub Actions tokens for ${var.github_owner}/${var.github_repo} only"

  # Only workflows in the configured repository can federate — regardless
  # of branch, event type, or environment.
  attribute_condition = "assertion.repository == \"${var.github_owner}/${var.github_repo}\""

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# principalSet grants access to every workflow run of the repository
# (pushes and PRs alike); the apply job is what actually changes GCP, and
# it is gated by GitHub environment approvals and branch protection.
resource "google_service_account_iam_member" "pipeline_wif" {
  service_account_id = google_service_account.pipeline.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_owner}/${var.github_repo}"
}
