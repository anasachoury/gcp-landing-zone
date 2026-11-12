# Day-2 operations

The normal way to change the landing zone: **open a PR, read the plan, merge.**
No `terraform apply` from laptops, no console clicks that silently become
drift.

## Add a project for a new workload

1. Append an entry to `catalogs/projects.yaml`:

   ```yaml
   - app: billing-api
     environment: production
     folder: production
     description: Billing service
     services:
       - run.googleapis.com
       - sqladmin.googleapis.com
     shared_vpc:
       attach: true
       subnet_users: [network-admins]
     service_accounts:
       - id: runtime
         display_name: Billing API runtime
         roles: [roles/secretmanager.secretAccessor]
     budget:
       amount: 150
       thresholds: [0.5, 0.9, 1.0]
     labels: { team: payments, app: billing-api }
   ```

2. Open a PR. CI validates the catalog; the `deploy` plan job shows the new
   project in stage 10-factory.
3. Merge. The apply job creates the project (right folder, APIs, shared VPC
   attachment, `compute.networkUser` on all subnets for the listed groups,
   service account with its roles, budget, labels) — typically 3–4 minutes.

Tear-down is the same PR flow in reverse: remove the entry. Projects have
`deletion_policy = "PREVENT"`, so a removed project enters the pending-
deletion state rather than vanishing on a merge; confirm with
`gcloud projects list --filter=lifecycleState:DELETE_PENDING`.

## Change an org policy

Edit `catalogs/org-policies.yaml`. Examples:

Lift a constraint in one folder only:

```yaml
- constraint: constraints/sql.restrictPublicIp
  type: list
  enforcement: deny
  exceptions: [sandbox]        # folder names from folders.yaml
```

Restrict regions to explicit ones:

```yaml
- constraint: constraints/gcp.resourceLocations
  type: list
  allowed_values: ["europe-west1", "europe-west4"]
```

Enforce the example custom constraint (defined in stage 03-security):

```yaml
- constraint: custom.allowedVmMachineFamilies
  type: boolean
  enforce: true
```

Merging applies org-level policies plus folder-level overrides for each
exception. Watch the 01-org plan: tightening a policy with existing
violating resources can fail the apply — the plan shows exactly which.

## Add a subnet or region

Edit `catalogs/networks.yaml` (subnets must not overlap — CI enforces it),
merge, and the 02-networking apply creates the subnet, a router and a NAT
gateway in that region. Projects attached via the factory automatically get
`compute.networkUser` on new subnets too, because the grant iterates over
all subnets in the VPC.

## Promote an app to production

Add a second entry for the same `app` with `environment: production`.
You get a separate project in the Production folder — never shared state
between environments.

## Rotate the pilot / start over with an app

Remove the project entries, let the factory apply remove the Terraform
records, then decide the projects' fate via `gcloud projects delete` or
restore. The landing zone itself is untouched.

## Drift happened — a change was made in the console

The nightly `drift-detection` run opens an issue listing the affected
stages. Either:

- re-run the deploy workflow on main to reconcile the resource back to the
  catalogs, or
- if the console change was right, codify it: update the catalog so the
  next plan is clean, then close the issue.

## Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| 01-org apply: `essentialcontacts` permission error | an org-level role list was trimmed | keep `roles/essentialcontacts.admin` in bootstrap, re-run bootstrap |
| 02-networking: `compute.googleapis.com not enabled` on host project | state was applied out of order | let the pipeline apply stages in order; the stage enables its own APIs |
| apply fails halfway | IAM/API enablement is eventually consistent | re-run the deploy job — applies are idempotent |
| plan job skipped on PR | repo variables missing (bootstrap not run) or PR from a fork | run bootstrap; fork PRs have no OIDC by design |
| `Error 409: folder exists` | folder created outside Terraform | import it: `terraform import 'google_folder.folders["production"]' folders/123456789` |
