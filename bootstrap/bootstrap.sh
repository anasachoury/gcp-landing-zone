#!/usr/bin/env bash
#
# Landing zone bootstrap — run ONCE from a machine where you are
# authenticated as a Google Cloud organization administrator.
#
# Creates (idempotently — safe to re-run):
#   1. a bootstrap project hosting pipeline resources
#   2. the Terraform state bucket (versioned, no public access)
#   3. the pipeline service account with curated org-level roles
#   4. a Workload Identity pool + GitHub OIDC provider for this repository
#
# Then prints the GitHub repository variables the pipelines need.
#
# Usage:
#   ./bootstrap/bootstrap.sh \
#     --github-owner my-org --github-repo gcp-landing-zone \
#     [--org-id 123456789012] [--billing-account 01ABCD-...] \
#     [--prefix lz] [--state-bucket my-bucket] [--auto-approve]
#
# Everything can also be provided via environment variables:
#   LZ_GITHUB_OWNER, LZ_GITHUB_REPO, LZ_ORG_ID, LZ_BILLING_ACCOUNT,
#   LZ_PREFIX, LZ_STATE_BUCKET, LZ_BOOTSTRAP_PROJECT_ID, LZ_STATE_BUCKET_LOCATION

set -euo pipefail

PREFIX="${LZ_PREFIX:-lz}"
ORG_ID="${LZ_ORG_ID:-}"
BILLING="${LZ_BILLING_ACCOUNT:-}"
GH_OWNER="${LZ_GITHUB_OWNER:-}"
GH_REPO="${LZ_GITHUB_REPO:-}"
BOOTSTRAP_PROJECT="${LZ_BOOTSTRAP_PROJECT_ID:-}"
BUCKET="${LZ_STATE_BUCKET:-}"
LOCATION="${LZ_STATE_BUCKET_LOCATION:-EU}"
AUTO_APPROVE=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="$2"; shift 2 ;;
    --billing-account) BILLING="$2"; shift 2 ;;
    --github-owner) GH_OWNER="$2"; shift 2 ;;
    --github-repo) GH_REPO="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --bootstrap-project-id) BOOTSTRAP_PROJECT="$2"; shift 2 ;;
    --state-bucket) BUCKET="$2"; shift 2 ;;
    --state-bucket-location) LOCATION="$2"; shift 2 ;;
    --auto-approve) AUTO_APPROVE=1; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown option: $1" >&2; usage ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' is required but not installed. $2" >&2
    exit 1
  }
}
need gcloud "Install from https://cloud.google.com/sdk/docs/install"
need terraform "Install from https://developer.hashicorp.com/terraform/downloads"

say "Checking gcloud authentication"
ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
[[ -n "$ACCOUNT" ]] || { echo "ERROR: not authenticated. Run: gcloud auth login" >&2; exit 1; }
echo "Active account: $ACCOUNT"

if [[ -z "$ORG_ID" ]]; then
  say "No --org-id given, auto-detecting"
  ORG_ID="$(gcloud organizations list --format='value(name)' 2>/dev/null | head -n1 || true)"
  [[ -n "$ORG_ID" ]] || {
    echo "ERROR: could not auto-detect the organization. Pass --org-id." >&2
    exit 1
  }
fi
echo "Organization: $ORG_ID"

if [[ -z "$BILLING" ]]; then
  echo "ERROR: --billing-account is required. Available billing accounts:" >&2
  gcloud billing accounts list --format='table(name,displayName)' >&2 || true
  exit 1
fi

[[ -n "$GH_OWNER" && -n "$GH_REPO" ]] || {
  echo "ERROR: --github-owner and --github-repo are required" >&2
  exit 1
}
echo "GitHub repository: ${GH_OWNER}/${GH_REPO}"

# --- 1. bootstrap project ---------------------------------------------------
[[ -n "$BOOTSTRAP_PROJECT" ]] || BOOTSTRAP_PROJECT="${PREFIX}-bootstrap"
say "Bootstrap project: $BOOTSTRAP_PROJECT"
if ! gcloud projects describe "$BOOTSTRAP_PROJECT" >/dev/null 2>&1; then
  gcloud projects create "$BOOTSTRAP_PROJECT" \
    --organization="$ORG_ID" \
    --name="Landing zone bootstrap"
else
  echo "Project exists, reusing."
fi

if [[ "$(gcloud billing projects describe "$BOOTSTRAP_PROJECT" --format='value(billingEnabled)' 2>/dev/null)" != "True" ]]; then
  say "Linking billing account $BILLING"
  gcloud billing projects link "$BOOTSTRAP_PROJECT" --billing-account="$BILLING"
fi

say "Enabling APIs on the bootstrap project"
SERVICES=(
  cloudresourcemanager.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  sts.googleapis.com
  serviceusage.googleapis.com
  cloudbilling.googleapis.com
  billingbudgets.googleapis.com
  essentialcontacts.googleapis.com
  orgpolicy.googleapis.com
  accesscontextmanager.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  compute.googleapis.com
  cloudidentity.googleapis.com
)
gcloud services enable --project="$BOOTSTRAP_PROJECT" "${SERVICES[@]}"

# --- 2. state bucket ---------------------------------------------------------
[[ -n "$BUCKET" ]] || BUCKET="${PREFIX}-tfstate"
say "Terraform state bucket: $BUCKET"
if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BUCKET" \
    --project="$BOOTSTRAP_PROJECT" \
    --location="$LOCATION" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi
gcloud storage buckets update "gs://$BUCKET" --versioning >/dev/null
echo "Bucket ready (versioned, uniform access, public access prevented)."

# --- 3. group sanity check ---------------------------------------------------
say "Checking groups from catalogs/groups.yaml"
CUSTOMER_ID="$(gcloud organizations describe "$ORG_ID" --format='value(owner.directoryCustomerId)')"
MISSING_GROUPS=()
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    if ! gcloud identity groups describe "$email" >/dev/null 2>&1; then
      MISSING_GROUPS+=("$email")
    fi
  done < <(python3 -c '
import yaml
with open("catalogs/groups.yaml") as fh:
    for g in yaml.safe_load(fh)["groups"]:
        print(g["email"])
' 2>/dev/null || true)
fi
if [[ ${#MISSING_GROUPS[@]} -gt 0 ]]; then
  echo "WARNING: these groups do not exist yet in Cloud Identity:" >&2
  for email in "${MISSING_GROUPS[@]}"; do echo "  - $email" >&2; done
  echo "IAM bindings reference them by email, so apply will succeed, but" >&2
  echo "nobody is in them yet. Create them (admin.google.com → Directory → Groups," >&2
  echo "or: gcloud identity groups create GROUP_EMAIL --organization=$CUSTOMER_ID \\" >&2
  echo "        --display-name=... --group-type=security) and add members." >&2
fi

# --- 4. terraform: seed SA + OIDC federation ---------------------------------
say "Applying bootstrap Terraform"
TF_DIR="$(cd "$(dirname "$0")/tf" && pwd)"
cd "$TF_DIR"

terraform init -input=false \
  -backend-config="bucket=$BUCKET" \
  -backend-config="prefix=landing-zone/bootstrap"

APPROVE_ARGS=()
[[ $AUTO_APPROVE -eq 1 ]] && APPROVE_ARGS=(-auto-approve)
terraform apply -input=false "${APPROVE_ARGS[@]}" \
  -var "org_id=$ORG_ID" \
  -var "billing_account=$BILLING" \
  -var "prefix=$PREFIX" \
  -var "bootstrap_project_id=$BOOTSTRAP_PROJECT" \
  -var "state_bucket=$BUCKET" \
  -var "github_owner=$GH_OWNER" \
  -var "github_repo=$GH_REPO"

# --- 5. instructions ---------------------------------------------------------
WIF_PROVIDER="$(terraform output -raw wif_provider)"
STATE_BUCKET_OUT="$(terraform output -raw state_bucket)"

cat <<EOF

=====================================================================
 Bootstrap complete.

 Next: set these GitHub repository VARIABLES
 (Settings → Secrets and variables → Actions → Variables tab):

   GCP_WIF_PROVIDER     = $WIF_PROVIDER
   GCP_STATE_BUCKET     = $STATE_BUCKET_OUT
   GCP_ORG_ID           = $ORG_ID
   GCP_BILLING_ACCOUNT  = $BILLING
   LZ_PREFIX            = $PREFIX

 With the gh CLI, from the repository root:

   gh variable set GCP_WIF_PROVIDER    --body "$WIF_PROVIDER"
   gh variable set GCP_STATE_BUCKET    --body "$STATE_BUCKET_OUT"
   gh variable set GCP_ORG_ID          --body "$ORG_ID"
   gh variable set GCP_BILLING_ACCOUNT --body "$BILLING"
   gh variable set LZ_PREFIX           --body "$PREFIX"

 Then:
   1. (Recommended) Settings → Environments → create "landing-zone"
      and add required reviewers — every apply will then need approval.
   2. Edit catalogs/groups.yaml (your domain) and catalogs/*.yaml to taste.
   3. Push to main. The deploy workflow applies stages 01→02→03→10.
=====================================================================
EOF
