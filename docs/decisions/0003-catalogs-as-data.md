# ADR-0003: Catalogs as data — YAML drives the stages

- Status: accepted
- Date: 2026-11-12

## Context

Landing zone changes fall into two very different groups: *structural*
(new resource types, new wiring — rare, careful Terraform work) and
*operational* (a new project, a new policy exception, one more subnet —
weekly platform-team routine). Making the second group require editing
Terraform invites copy-paste errors and meaningless diffs.

## Decision

Operational data lives in five YAML files under `catalogs/`:

- `folders.yaml`, `groups.yaml`, `org-policies.yaml` → stage 01-org
- `networks.yaml` → stage 02-networking
- `projects.yaml` → stage 10-factory

The Terraform stages stay stable and render resources from the catalogs
(`yamldecode` + `for_each`). `scripts/validate_catalogs.py` enforces the
schema — uniqueness, cross-references, CIDR overlaps, GCP name limits —
in CI before Terraform runs.

## Consequences

- Adding a project or lifting a policy for a folder is a small, reviewable
  YAML diff; the PR template routes it.
- Catalog mistakes (overlapping CIDRs, unknown folder names, 31-character
  project ids) fail fast in CI with a precise message instead of a
  Terraform error mid-apply.
- The YAML schema is implicitly defined by the validator and the stages;
  changing it means updating both. The validator is deliberately strict to
  keep them honest.
- Anything the catalogs cannot express falls back to normal Terraform in
  the stage — the escape hatch is always open.
