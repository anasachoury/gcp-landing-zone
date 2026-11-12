output "seed_sa_email" {
  description = "Pipeline service account email."
  value       = google_service_account.pipeline.email
}

output "wif_provider" {
  description = "Full WIF provider resource name for google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "state_bucket" {
  description = "Terraform state bucket."
  value       = var.state_bucket
}

output "bootstrap_project_id" {
  description = "Project hosting bootstrap resources."
  value       = var.bootstrap_project_id
}

output "github_variables" {
  description = "Variables to set on the GitHub repository."
  value       = <<-EOT
    Set these as GitHub repository VARIABLES (not secrets — none of them are
    credentials). Settings → Secrets and variables → Actions → Variables:

      GCP_WIF_PROVIDER     = ${google_iam_workload_identity_pool_provider.github.name}
      GCP_STATE_BUCKET     = ${var.state_bucket}
      GCP_ORG_ID           = ${var.org_id}
      GCP_BILLING_ACCOUNT  = ${var.billing_account}
      LZ_PREFIX            = ${var.prefix}
  EOT
}
