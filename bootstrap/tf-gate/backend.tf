terraform {
  # Partial backend config — bootstrap.sh passes:
  #   -backend-config=bucket=<state bucket> -backend-config=prefix=landing-zone/github-gate
  backend "gcs" {}
}
