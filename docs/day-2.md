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
   service account with its roles, budget, labels, and the `environment` tag)
   — typically 3–4 minutes.

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

Apply a constraint to one folder instead of the whole organization:

```yaml
- constraint: constraints/iam.disableServiceAccountCreation
  type: boolean
  enforce: true
  folder: sandbox              # no exceptions alongside this — CI rejects it
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

Values may reference `${org_id}` and `${prefix}`; stage 01-org substitutes them
before the policy is rendered. That is how `compute.restrictVpcPeering` can say
`under:organizations/${org_id}` without a hardcoded number.

Merging applies org-level policies, folder-level policies, and folder-level
overrides for each exception. Watch the 01-org plan: tightening a policy with
existing violating resources can fail the apply — the plan shows exactly which.

The validator knows the per-constraint rules the API enforces, so most
mistakes fail CI instead of the apply: `iam.allowedPolicyMemberDomains` and
`iam.serviceAccountKeyExpiryHours` accept only allowed values,
`serviceAccountKeyExpiryHours` takes exactly one of the fixed durations, and
the two `restrict*` network constraints need `under:`/`is:` paths.

## Turn on domain-restricted sharing

`iam.allowedPolicyMemberDomains` is the control that stops a resource from
being shared with an identity outside your organization. It ships enforced,
because a landing zone without it is a landing zone that can be opened to
`allUsers` by any project owner.

If your organization already has external principals in its IAM policy — a
contractor's personal Gmail, a partner's domain, an old `allUsers` binding on
a bucket — read this before the first apply:

1. **Inventory what violates it.** Any binding whose member is a `user:`,
   `group:` or `domain:` outside your domain will make the next
   `SetIamPolicy` fail with `FAILED_PRECONDITION: One or more users named in
   the policy do not belong to a permitted customer` — including the group
   grants in stage 01-org itself.

   ```bash
   gcloud organizations get-iam-policy ORG_ID --format=json \
     | jq -r '.bindings[] | "\(.role) \(.members[])"' | grep -v "@your-domain.com"
   ```

2. **Remove or replace them first.** Either drop the binding, or move the
   outside identity into a group in your domain and grant the group.

3. **Then merge the catalog entry.** If a single apply has to both enforce the
   policy and write IAM, Terraform's ordering may enforce first and fail the
   rest of the stage. Enforcing it as its own PR — catalog entry only, no other
   change — makes the failure mode obvious.

To lift it in one folder (rarely what you want — it reopens the hole for
everything under that folder), add `exceptions: [sandbox]` to the entry.

## Change what gets audited

`catalogs/audit-logs.yaml` has three parts:

- `audit_config.all_services` — the baseline Data Access log types for every
  service (`DATA_WRITE` by default; `ADMIN_READ` is always on and cannot be
  turned off).
- `audit_config.services` — per-service overrides. Add an entry when reading
  the data is itself the security event:

  ```yaml
  - service: healthcare.googleapis.com
    log_types: [DATA_READ, DATA_WRITE]
  ```

  Data Access logs are billed by volume. `DATA_READ` on a busy bucket is the
  single most expensive line item a landing zone can create, which is why the
  default is per-service rather than org-wide.

- `buckets` — one bucket and one organization-wide sink per entry, each with
  its own filter and retention. Adding a class of logs is a three-line diff:

  ```yaml
  - id: gke-audit
    description: GKE audit and control plane logs
    retention_days: 90
    filter: logName:"cloudaudit.googleapis.com%2Factivity" AND resource.type="k8s_cluster"
  ```

- `exports` — `bigquery` and `pubsub`, each with an `enabled` switch. Turning
  one on creates the destination and the writer grant; turning it off removes
  them but leaves the data where it is.

## Turn on CMEK for landing zone storage

The org policy already requires CMEK for Cloud SQL, Secret Manager, GKE and
Artifact Registry. Storage and BigQuery are deliberately not in that list yet,
because the landing zone's own log buckets and audit dataset would fail their
own policy. To close that gap:

1. Point the log buckets at the key from stage 03-security by adding a
   `cmek_settings` block to `google_logging_project_bucket_config.buckets`:

   ```hcl
   cmek_settings {
     kms_key_name = data.terraform_remote_state.security.outputs.kms_key
   }
   ```

   That needs the key to exist first, so either move the keyring into 01-org or
   accept a second apply.

2. Give the logging service agent `roles/cloudkms.cryptoKeyEncrypterDecrypter`
   on the key.

3. Add the services to `denied_values` under
   `constraints/gcp.restrictNonCmekServices` and merge.

Do it in that order. Adding the policy first blocks the next apply's bucket
creation, and the error message ("constraint violated") does not tell you that
the landing zone is the thing violating it.

## Tag a project

Tags are defined once in `catalogs/tags.yaml` and bound to projects by the
factory. The `environment` tag is automatic. Anything else is one field:

```yaml
- app: billing-api
  environment: production
  folder: production
  data_classification: confidential   # value from tags.yaml
```

Policy and IAM conditions can then match on it without knowing project ids:

```hcl
# an IAM condition, or an org policy rule condition
resource.matchTag("ORGANIZATION_ID/environment", "production")
```

Adding a tag value is a two-line diff in `tags.yaml`; removing one that a
project still uses fails CI rather than the apply.

## Act on Security Command Center findings

Stage 03-security creates two things:

- a Pub/Sub topic (`lz-scc-findings`) receiving `state="ACTIVE"` findings at
  HIGH or CRITICAL severity — subscribe a Cloud Function, a PagerDuty
  integration or your SOAR tool to it;
- a BigQuery dataset (`lz_scc_findings`) with a continuous export of every
  active finding, so "how long has this been open" is a query, not a console
  session.

```sql
SELECT finding.category, COUNT(*) AS open_findings
FROM `PROJECT.lz_scc_findings.findings`
WHERE finding.state = 'ACTIVE'
GROUP BY 1 ORDER BY 2 DESC
```

If the organization is on SCC Standard rather than Premium, fewer detectors
run but nothing here needs changing.

## Move the VPC-SC perimeter from dry-run to enforce

1. Set `enable_vpc_sc = true` and leave `vpc_sc_mode = "dry_run"` (the
   default), then merge. The perimeter logs what it *would* have blocked and
   blocks nothing.
2. After a couple of weeks, read the violations in Logging:

   ```
   logName:"cloudaudit.googleapis.com%2Fpolicy"
   protoPayload.metadata.dryRun="true"
   ```

3. Add the missing access levels, ingress rules or restricted services to
   `stages/03-security/main.tf`.
4. Flip `vpc_sc_mode = "enforce"` in a PR and read the plan carefully. This is
   the change that can lock a team out of their own project.

Note that only one access policy can exist per organization. If yours already
has one, set `enable_vpc_sc = false` and add the perimeter to the existing
policy by hand — or import it.

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
| 01-org apply: `409 There were concurrent policy changes` | several audit config entries writing the same organization IAM policy | re-run the apply — Terraform retries; the `allServices` entry is already ordered first |
| 03-security: `Requested entity already exists` on SCC config | SCC resources were created in the console first | `terraform import` them, or delete the console copies |
| 03-security: SCC resources 403 | organization is not enrolled in SCC | enroll at the organization (console → Security → Settings); Standard is enough |
| Any apply: `constraint ... violated` right after enabling a policy | the policy is newer than the resources it now covers | remove the constraint from the catalog, apply, fix the resources, re-add it |

## Upgrading from the single-sink layout

The log bucket, its sink and the writer grant used to be single resources.
They are now catalog-driven collections, and stage 01-org carries `moved`
blocks so the first apply after the upgrade updates them in place instead of
recreating the audit trail. If you had renamed anything by hand, check the plan
for `must be replaced` on `google_logging_organization_sink.buckets` before
merging.

`audit_retention_days` was removed as a variable: retention now lives per
bucket in `catalogs/audit-logs.yaml`, so the DNS bucket can keep 30 days while
admin activity keeps 365. Drop the variable from any local `tfvars`.
