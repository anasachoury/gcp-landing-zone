# gcp-landing-zone

A lean, **GitHub-native** landing zone for Google Cloud: folders, group IAM,
an org policy library, a shared VPC, central logging, security alerting, and
a project factory — deployed entirely from GitHub Actions with
**zero stored credentials**.

```
Organization
├── Common          → lz-logging (audit logs, metrics, alerts, KMS)
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
  --prefix lz \
  --github-token "$GH_PAT" --reviewer-users alice,bob

# 2. set the five repository variables it prints (gh commands are printed
#    for you — none of them are secrets)

# 3. edit the catalogs to your reality:
#    catalogs/groups.yaml  (your domain, your groups)
#    catalogs/org-policies.yaml  (your allowed regions)
#    catalogs/networks.yaml (your CIDRs)
#    catalogs/projects.yaml (delete the pilot, add your apps)

# 4. push to main. The deploy workflow applies:
#    01-org → 02-networking → 03-security → 10-factory
```

The `--github-token` / `--reviewer-users` step configures the
`landing-zone` GitHub environment with required reviewers
([bootstrap/tf-gate](bootstrap/tf-gate)): every apply then waits for a
human approval, and the person who pushed cannot approve it themselves
(the two-human rule). The token needs repo admin (or fine-grained:
Environments read/write) and is used only for that one configuration
step — never stored anywhere. Skip it and the deploy workflow's gate job
fails every apply with instructions on how to fix it; the gate cannot
be forgotten silently. Solo operator? Use
`--reviewer-users you --allow-self-review` and the apply is still
click-gated, just by yourself.

First run takes ~10 minutes; afterwards plans and applies are incremental.
Note: CI intentionally fails on the pristine fork with
`example.com placeholder left in` until you set your domain in
`catalogs/groups.yaml` — that gate is [the catalog validator](scripts/validate_catalogs.py)
doing its job.

## What each stage delivers

| Stage | Creates |
| --- | --- |
| `bootstrap/` (once, local) | state bucket, pipeline service account (no keys), WIF pool + GitHub OIDC provider, curated org roles |
| `stages/01-org` | folder taxonomy, group IAM bindings, org policy library with per-folder exceptions, central logging project + org audit sink + retention, essential contacts, org budget + email alerts |
| `stages/02-networking` | shared VPC host project, subnets + secondary ranges, Cloud NAT per region, private DNS zone, hierarchical firewall policy (IAP-only SSH/RDP, deny public, allow internal) |
| `stages/03-security` | CMEK-ready KMS keyring + key, break-glass alerting (org IAM / policy changes / SA key creation → email within a minute), example custom org policy constraint, optional dry-run VPC-SC perimeter |
| `stages/10-factory` | every project in `catalogs/projects.yaml`: folder placement, APIs, shared VPC attach, subnet IAM, service accounts + roles, budget, labels |

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
| [catalogs/groups.yaml](catalogs/groups.yaml) | groups + IAM bindings |
| [catalogs/org-policies.yaml](catalogs/org-policies.yaml) | org policies + folder exceptions |
| [catalogs/networks.yaml](catalogs/networks.yaml) | VPC, subnets, NAT, DNS |
| [catalogs/projects.yaml](catalogs/projects.yaml) | the project factory |

## Security model

- **No service account keys exist** — and the shipped policy library disables
  their creation org-wide. The pipeline uses GitHub OIDC tokens (1 h lifetime,
  repository-scoped by attribute condition).
- **IAM binds to groups, never users.** Humans are added to groups, not to
  resources.
- **Every apply is gated** — PR plans first; the apply runs through the
  `landing-zone` GitHub environment, which [bootstrap/tf-gate](bootstrap/tf-gate)
  configures with required reviewers and `prevent_self_review`: the person
  who pushed cannot approve their own apply (two-human rule). A gate job in
  the deploy workflow fails the run if the reviewers are ever missing.
- **Break-glass is alerted, not blocked**: org IAM changes, org policy
  changes, and SA key creation email the security group within a minute.
- **Nightly drift detection** opens an issue when reality and Terraform
  disagree.

Details: [docs/architecture.md](docs/architecture.md) ·
[docs/pipeline.md](docs/pipeline.md).

## Repository layout

```
bootstrap/          run once, from an org admin's laptop
  tf-gate/          the reviewer gate on the landing-zone GitHub environment
stages/
  01-org/           folders, IAM, policies, logging, budget
  02-networking/    shared VPC, NAT, DNS, hierarchical firewall
  03-security/      KMS, break-glass alerts, custom constraints, VPC-SC
  10-factory/       projects from the catalog
catalogs/           the five YAML files a platform team edits
scripts/            catalog validation (runs in CI)
docs/               architecture, prerequisites, pipeline, day-2, ADRs
.github/workflows/  ci (static) · deploy (plan + gate + apply) · drift (nightly)
```

## Roadmap

- Entra ID / Okta federation notes for group membership
- CIS benchmark mapping for the policy library
- Optional Interconnect/VPN stage (the firewall policy already reserves
  internal ranges for it)

## Contributing

PRs welcome — open an issue first for anything structural. Catalogs are
validated and stages are `terraform validate`d in CI; keep the lean scope in
mind (see the [ADRs](docs/decisions/)).

## License

Apache 2.0 — see [LICENSE](LICENSE).
