terraform {
  # Partial backend config — CI and the Makefile pass:
  #   -backend-config=bucket=<bucket> -backend-config=prefix=landing-zone/02-networking
  backend "gcs" {}
}
