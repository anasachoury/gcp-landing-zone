# gcp-landing-zone

A lean, **GitHub-native** landing zone for Google Cloud: folders, group IAM,
a 21-constraint org policy library, a shared VPC, central logging with Data
Access logs and BigQuery/Pub-Sub exports, Security Command Center findings
export, resource tags, break-glass access, and a project factory — deployed
entirely from GitHub Actions with **zero stored credentials**.

```
Organization
├── Common          → lz-logging (audit logs, exports, SCC findings, KMS)
│                   → lz-net-host (shared VPC, NAT, DNS, hierarchical firewall)
├── Production      → factory projects (catalogs/projects.yaml)
├── Non-Production
├── Development
└── Sandbox         → org policy exceptions live here
```

## Why another landing zone repo

The existing references are excellent and heavy: Google's
[terraform-example-foundation](https://github.com/GoogleCloudPlatform/terraform-example-foundation)
assumes Cloud Build and multi-repo; [Cloud Foundation Fabric
FAST](https://github.com/GoogleCloudPlatform/cloud-foundation-fabric) brings
its own module suite. This repo takes a different position:

| | This repo | TEF / FAST |
| --- | --- | --- |
| CI/CD | GitHub Actions only, via OIDC federation | Cloud Build / Jenkins / GitLab |
| Stored credentials | **none** — five repo *variables*, zero secrets | service account key in the CI system |
| Shape | one monorepo, four stages, one apply job | multi-repo or staged pipeline buildout |
| Day-to-day changes | edit a YAML catalog, open a PR | edit Terraform |
| Modules | plain provider resources (readable in place) | CFT / Fabric module suites |

The trade-off: fewer features, less structure, more of everything visible at
a glance. If you outgrow it, graduating to TEF or FAST is natural — the org
layout, policies, and network this creates are theirs, too.

## Quickstart

Prerequisites (org, billing account, admin role, three groups, local tools)
are listed in [docs/prerequisites.md](docs/prerequisites.md).

```bash
# 1. from a machine where you are org admin:
./bootstrap/bootstrap.sh \
  --github-owner your-org --github-repo gcp-landing-zone \
  --org-id 123456789012 --billing-account 01ABCD-123456-7890EF \
  --prefix lz

# 2. set the five repository variables it prints (gh commands are printed
#    for you — none of them are secrets)

# 3. edit the catalogs to your reality:
#    catalogs/groups.yaml  (your groups, your break-glass accounts)
#    catalogs/org-policies.yaml  (your allowed regions)
#    catalogs/audit-logs.yaml  (Data Access logs, retention, exports)
#    catalogs/networks.yaml (your CIDRs)
#    catalogs/projects.yaml (delete the pilot, add your apps)

# 4. push to main. The deploy workflow applies:
#    01-org → 02-networking → 03-security → 10-factory
```

First run takes ~10 minutes; afterwards plans and applies are incremental.

The identity domain is `tuniclic.tech`, set in both `catalogs/groups.yaml`
(group addresses) and `catalogs/org-policies.yaml` (the domain allowed by
domain-restricted sharing). CI cross-checks that the domains you allow
actually cover the groups you grant roles to, so the two cannot drift apart.
On a fresh fork that gate fails with `example.com placeholder left in` until
both files are set — [the catalog validator](scripts/validate_catalogs.py)
doing its job, not a broken pipeline.

## What each stage delivers

| Stage | Creates |
| --- | --- |
| `bootstrap/` (once, local) | state bucket, pipeline service account (no keys), WIF pool + GitHub OIDC provider, curated org roles |
| `stages/01-org` | folder taxonomy, group IAM bindings, 21-constraint org policy library with per-folder scoping and exceptions, central logging project, Data Access audit configuration, four log buckets + sinks (admin, data access, network, DNS), BigQuery and Pub/Sub audit exports, org-defined resource tags, essential contacts, org budget |
| `stages/02-networking` | shared VPC host project, subnets + secondary ranges, Cloud NAT per region, private DNS zone with query logging, hierarchical firewall policy (IAP-only SSH/RDP, deny public, allow internal) |
| `stages/03-security` | CMEK keyring + key, Security Command Center findings feed (Pub/Sub) and continuous BigQuery export, break-glass and sensitive-change alerting, example custom org policy constraint, optional VPC-SC perimeter with access level and ingress/egress rules |
| `stages/10-factory` | every project in `catalogs/projects.yaml`: folder placement, APIs, shared VPC attach, subnet IAM, service accounts + roles, environment and data-classification tags, budget, labels |

## The catalogs

Day-to-day changes are YAML diffs, reviewed like code:

```yaml
# catalogs/projects.yaml — a new compliant project is one entry
- app: billing-api
  environment: production
  folder: production
  services: [run.googleapis.com, sqladmin.googleapis.com]
  shared_vpc:
    attach: true
    subnet_users: [network-admins]
  service_accounts:
    - id: runtime
      roles: [roles/secretmanager.secretAccessor]
  budget: { amount: 150, thresholds: [0.5, 0.9, 1.0] }
  labels: { team: payments, app: billing-api }
```

| Catalog | Drives |
| --- | --- |
| [catalogs/folders.yaml](catalogs/folders.yaml) | folder taxonomy |
| [catalogs/groups.yaml](catalogs/groups.yaml) | groups, IAM bindings, break-glass accounts |
| [catalogs/org-policies.yaml](catalogs/org-policies.yaml) | org policies, folder scoping, folder exceptions |
| [catalogs/audit-logs.yaml](catalogs/audit-logs.yaml) | Data Access logs, log buckets, retention, exports |
| [catalogs/tags.yaml](catalogs/tags.yaml) | resource tag keys and values |
| [catalogs/networks.yaml](catalogs/networks.yaml) | VPC, subnets, NAT, DNS |
| [catalogs/projects.yaml](catalogs/projects.yaml) | the project factory |

## Security model

- **No service account keys exist** — and the shipped policy library disables
  their creation *and* their upload org-wide. The pipeline uses GitHub OIDC
  tokens (1 h lifetime, repository-scoped by attribute condition).
- **Sharing stops at the organization boundary.** Domain-restricted sharing
  (`iam.allowedPolicyMemberDomains`) rejects any attempt to grant a role to
  an identity outside your domain — including `allUsers`.
- **IAM binds to groups, never users.** Humans are added to groups, not to
  resources.
- **Data Access logs are on** for the services that hold the data, and the
  audit trail goes three ways: log buckets with per-class retention, a
  BigQuery dataset, and a Pub/Sub feed for a SIEM.
- **Findings, not just logs.** Security Command Center findings stream to
  Pub/Sub and export continuously to BigQuery.
- **Break-glass exists and is alarmed.** Two emergency accounts, an empty
  `break-glass` group holding the repair roles, and an alert on any use —
  see [docs/break-glass.md](docs/break-glass.md).
- **Every apply is gated** — PR plans first; the apply runs through the
  `landing-zone` GitHub environment (add required reviewers for a
  two-human rule).
- **Nightly drift detection** opens an issue when reality and Terraform
  disagree.

Details: [docs/architecture.md](docs/architecture.md) ·
[docs/pipeline.md](docs/pipeline.md).

## Repository layout

```
bootstrap/          run once, from an org admin's laptop
stages/
  01-org/           folders, IAM, policies, logging, audit exports, tags
  02-networking/    shared VPC, NAT, DNS, hierarchical firewall
  03-security/      KMS, SCC findings export, break-glass alerts, VPC-SC
  10-factory/       projects from the catalog
catalogs/           the seven YAML files a platform team edits
scripts/            catalog validation (runs in CI)
docs/               architecture, prerequisites, pipeline, day-2, break-glass, ADRs
.github/workflows/  ci (static) · deploy (plan + apply) · drift (nightly)
```

## Roadmap

- Entra ID / Okta federation notes for group membership
- CIS benchmark mapping for the policy library
- Optional Interconnect/VPN stage (the firewall policy already reserves
  internal ranges for it)
- Firewall rules keyed on secure tags (`target_secure_tags` needs provider
  v6; the tag keys are already defined for it)

## Contributing

PRs welcome — open an issue first for anything structural. Catalogs are
validated and stages are `terraform validate`d in CI; keep the lean scope in
mind (see the [ADRs](docs/decisions/)).

## License

Apache 2.0 — see [LICENSE](LICENSE).
