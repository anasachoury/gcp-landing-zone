# ADR-0005: Pin terraform-google provider to 5.x

- Status: accepted
- Date: 2026-11-12

## Context

The Google provider has a v6 line with breaking changes (renamed fields,
changed defaults, removed resources). A landing zone is the worst place for
a surprise major upgrade: it touches folders, IAM, and org policies, where
a failed apply is loud and a wrong apply is worse.

## Decision

All root modules pin `hashicorp/google` to `~> 5.44` (latest 5.x line at
the time of writing). Upgrades to v6 are a deliberate, planned change with
the migration guide in hand, not something Dependabot can decide.

## Consequences

- Applies are reproducible; provider behavior changes only when we choose.
- The repository may lag behind new v6-only resources — fine: the current
  resource set is complete for the shipped stages.
- Moving to v6 later means one PR (bump five pins), a full plan review,
  and the same pipeline — the structure does not change.
- Dependabot is configured for GitHub Actions only, on purpose; provider
  upgrades stay human decisions.
