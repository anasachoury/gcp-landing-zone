# Prerequisites

Before running bootstrap, you need:

## Google Cloud side

1. **An organization** (`gcloud organizations list` shows it). The free
   [Cloud Identity](https://cloud.google.com/identity) edition is enough —
   a Workspace domain also works.
2. **A billing account** the organization can use. You need
   `roles/billing.admin` on it, or an owner who can grant the pipeline the
   billing roles listed in [bootstrap/README.md](../bootstrap/README.md).
3. **Organization Administrator** (`roles/resourcemanager.organizationAdmin`)
   on the organization — bootstrap grants org-level roles and creates the
   WIF pool.
4. **The four groups from `catalogs/groups.yaml`**, created in your
   identity domain (`lz-admins`, `network-admins`, `security-admins`,
   `break-glass` by default). Bootstrap checks and tells you if they are
   missing. Either create them in the Admin console (Directory → Groups) or:

   ```bash
   gcloud identity groups create lz-admins@example.com \
     --organization=CUSTOMER_ID \
     --display-name="Landing Zone Admins" \
     --group-type=security
   ```

   `CUSTOMER_ID` is printed by
   `gcloud organizations describe ORG_ID --format='value(owner.directoryCustomerId)'`.

5. **Two emergency accounts** for break-glass access, with no standing GCP
   role, strong MFA, and credentials held offline with dual control. Their
   addresses go in `catalogs/groups.yaml` under `break_glass.accounts`. The
   full setup — including the super-admin assignment and the alert test — is
   in [break-glass.md](break-glass.md). Do it before you need it.

6. **Security Command Center enrolled** on the organization. Standard tier is
   the default and is enough for everything stage 03-security does; Premium
   adds detectors and is a billing action in the console (Security → Settings
   → Activate Premium). If you skip this, set `enable_scc = false` for
   stage 03-security.

## Local tools

- `gcloud` — [install](https://cloud.google.com/sdk/docs/install), then
  `gcloud auth login` with the admin account
- `terraform` >= 1.6 — [install](https://developer.hashicorp.com/terraform/downloads)
- `jq` (used by bootstrap.sh)
- `python3` + `pyyaml` (catalog validation; `pip install pyyaml` if missing)

## GitHub side

- A repository for this code (fork, push, or template — your choice).
- Permission to set repository **variables** (repo admin) — bootstrap
  prints the exact five to set, with `gh variable set` commands ready to
  paste.
- Optional but recommended: create the `landing-zone` environment with
  required reviewers, so every apply needs a human click.

## Costs to expect

| Item | Rough cost |
| --- | --- |
| Bootstrap + logging + host projects | none (projects are free) |
| Log storage | free up to 50 GiB/project assignment, then ~$0.01/GiB/month |
| **Data Access logs** | **billed by volume — the one line item to watch** |
| BigQuery audit export | storage only (partitioned tables, ~$0.02/GiB/month) |
| Pub/Sub audit feed | ~$0.04/GiB, and only if something subscribes |
| Cloud NAT | ~$12/month per region (running) + data processed |
| Monitoring | free tier covers the landing zone metrics and alerts |
| KMS key | ~$0.06/month per key version |
| SCC Premium (optional) | per-asset subscription, billed by Google |

Data Access logging is the expensive half of this landing zone, by design: the
default enables `DATA_WRITE` everywhere and `DATA_READ` only for the services
that hold data. Watch the `data-access` bucket size for a month before adding
services to `audit_config.services`.

Budgets (per project and org-wide) are wired from the catalogs; the org
budget is off until you set `org_budget_amount`.
