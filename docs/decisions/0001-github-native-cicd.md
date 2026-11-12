# ADR-0001: GitHub Actions is the only CI/CD — no Cloud Build

- Status: accepted
- Date: 2026-11-12

## Context

The reference foundations (Google's terraform-example-foundation, Cloud
Foundation Fabric FAST) deploy themselves with Cloud Build, Jenkins, or
GitLab. That requires the *bootstrap* to create or adopt a build system,
wire credentials into it, and operate it. Many teams already run everything
through GitHub Actions and do not want a second CI system.

## Decision

GitHub Actions is the only execution environment. Workloads federate via a
Workload Identity pool and provider pinned to this repository by attribute
condition; every job exchanges a fresh GitHub OIDC token for a short-lived
access token. Cloud Build is not used anywhere.

## Consequences

- No service account keys exist, and SA key creation is disabled org-wide
  by the shipped policy library — the design enforces itself.
- The bootstrap is small (one script, one Terraform root) because it does
  not provision a CI system.
- Teams not on GitHub cannot use this repository as-is; the pipeline is
  one job template, so porting to GitLab CI (which also supports OIDC
  federation to GCP) is realistic.
- GitHub Actions concurrency limits apply; applies serialize anyway, so
  this is fine.
