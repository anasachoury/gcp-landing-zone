# ADR-0004: Plain provider resources, not module suites

- Status: accepted
- Date: 2026-11-12

## Context

The usual building blocks are the Cloud Foundation Toolkit modules
(project-factory, network, org-policy) or Fabric's module suite. They are
solid, but they add a dependency graph, version pinning across a dozen
modules, and abstraction layers a small platform team must eventually debug
through.

## Decision

Stages use plain `google` provider resources (`google_project`,
`google_org_policy_policy`, `google_compute_subnetwork`, ...). The only
"framework" is the catalog rendering in locals.

## Consequences

- Everything is readable in place: what a project gets is visible in
  10-factory/main.tf, not spread across a module tree.
- No module version churn; upgrades are provider upgrades (see ADR-0005).
- The repository does not benefit from upstream module fixes — it carries
  its own implementation of common patterns.
- Teams that prefer CFT modules can swap them in per stage; the catalogs
  and the pipeline do not care what creates the resources.
