terraform {
  # Partial backend config — CI and the Makefile pass:
  #   -backend-config=bucket=<bucket> -backend-config=prefix=landing-zone/01-org
  backend "gcs" {}
}
