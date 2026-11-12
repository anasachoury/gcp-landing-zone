# Bootstrap (stage 00)

Run once, from a laptop, as an organization administrator. Everything after
this runs in GitHub Actions with no credentials stored anywhere.

```
./bootstrap.sh \
  --github-owner my-org \
  --github-repo gcp-landing-zone \
  --org-id 123456789012 \
  --billing-account 01ABCD-123456-7890EF \
  --prefix lz
```

Prerequisites are in [docs/prerequisites.md](../docs/prerequisites.md).

## What it creates

| Resource | Notes |
| --- | --- |
| `<prefix>-bootstrap` project | Hosts pipeline resources; small and boring on purpose |
| `<prefix>-tfstate` bucket | Terraform state: versioned, uniform access, public access prevented |
| `<prefix>-pipeline` service account | **No keys, ever.** Used only via GitHub OIDC |
| Workload Identity pool + provider | Trusts `https://token.actions.githubusercontent.com`, restricted to `owner/repo` by attribute condition |

The script is idempotent: it reuses anything that already exists, and
`terraform apply` converges. Re-run it freely after fixing a problem.

## Roles the pipeline service account gets

| Role | Why |
| --- | --- |
| `roles/resourcemanager.projectCreator` | project factory: create projects |
| `roles/resourcemanager.folderAdmin` | create folders, grant folder IAM |
| `roles/resourcemanager.organizationViewer` | read the organization |
| `roles/resourcemanager.projectIamAdmin` | grant IAM inside projects it creates |
| `roles/orgpolicy.policyAdmin` | apply the org policy library |
| `roles/compute.xpnAdmin` | shared VPC host + service attachments |
| `roles/logging.configWriter` | organization-level log sinks |
| `roles/essentialcontacts.admin` | org-level essential contacts |
| `roles/serviceusage.serviceUsageAdmin` | enable APIs on new projects |
| `roles/accesscontextmanager.policyAdmin` | optional VPC-SC perimeter (stage 03) |
| `roles/billing.user` | link projects to the billing account |
| `roles/billing.admin` | create budgets (broad on purpose — reduce later) |

Stages grant the pipeline additional *project-scoped* roles on the central
logging project as needed (logging admin, monitoring editor, KMS admin) —
made possible by org-level `projectIamAdmin`.

## Why no secrets in GitHub

Everything the pipelines need is a **variable**, not a secret: org id,
billing account, bucket, WIF provider name, prefix. None of them grant
access on their own — access only comes from GitHub-issued OIDC tokens,
which GitHub signs fresh for every job. If a token leaks, it is useless
after the job ends; there is nothing to rotate.

## Teardown / recovery

The bootstrap Terraform state lives in `gs://<prefix>-tfstate` under prefix
`landing-zone/bootstrap`. Do not delete that bucket unless you intend to
abandon the landing zone. To re-run bootstrap on a fresh clone, the same
command reproduces everything.
