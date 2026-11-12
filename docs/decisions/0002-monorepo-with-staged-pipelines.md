# ADR-0002: Monorepo with staged applies, not multi-repo

- Status: accepted
- Date: 2026-11-12

## Context

terraform-example-foundation splits into per-stage repositories after
bootstrap. That scales for large platform teams but is heavy for everyone
else: five repos, five CI setups, cross-repo version pinning, and a change
that spans stages needs five PRs.

## Decision

One repository. Each stage is a directory with its own Terraform state;
the deploy workflow applies stages sequentially in dependency order
(01-org → 02-networking → 03-security → 10-factory) in a single job.
Stages read earlier stages' outputs via `terraform_remote_state`, never
hardcoded ids.

## Consequences

- A cross-cutting change (new folder + new project using it) is one PR.
- The whole landing zone is reviewable in one place; CODEOWNERS routes
  everything through the platform team.
- One bad apply can stop later stages — visible in the same job log, and
  re-running the job re-applies idempotently from the top.
- If an organization outgrows this, splitting a stage out is mechanical:
  it is already an independent root module with its own state.
