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
#   5. the reviewer-gated "landing-zone" GitHub environment (--github-token)
#
# Then prints the GitHub repository variables the pipelines need.
#
# Usage:
#   ./bootstrap/bootstrap.sh \
#     --github-owner my-org --github-repo gcp-landing-zone \
#     [--org-id 123456789012] [--billing-account 01ABCD-...] \
#     [--prefix lz] [--state-bucket my-bucket] [--auto-approve]
#
# To also configure the apply gate (recommended, required for the documented
# two-human rule):
#   --github-token <PAT>            token with repo admin (or fine-grained:
#                                   Environments read/write on this repo)
#   --reviewer-users alice,bob      GitHub logins who approve applies
#   --reviewer-teams platform-team  GitHub team slugs (org repos)
#   --allow-self-review             solo operator: you pushed, you approve
#
# Everything can also be provided via environment variables:
#   LZ_GITHUB_OWNER, LZ_GITHUB_REPO, LZ_ORG_ID, LZ_BILLING_ACCOUNT,
#   LZ_PREFIX, LZ_STATE_BUCKET, LZ_BOOTSTRAP_PROJECT_ID, LZ_STATE_BUCKET_LOCATION,
#   LZ_GITHUB_TOKEN, LZ_REVIEWER_USERS, LZ_REVIEWER_TEAMS, LZ_ALLOW_SELF_REVIEW

set -euo pipefail

PREFIX="${LZ_PREFIX:-lz}"
ORG_ID="${LZ_ORG_ID:-}"
BILLING="${LZ_BILLING_ACCOUNT:-}"
GH_OWNER="${LZ_GITHUB_OWNER:-}"
GH_REPO="${LZ_GITHUB_REPO:-}"
BOOTSTRAP_PROJECT="${LZ_BOOTSTRAP_PROJECT_ID:-}"
BUCKET="${LZ_STATE_BUCKET:-}"
LOCATION="${LZ_STATE_BUCKET_LOCATION:-EU}"
GH_TOKEN_GATE="${LZ_GITHUB_TOKEN:-}"
REVIEWER_USERS="${LZ_REVIEWER_USERS:-}"
REVIEWER_TEAMS="${LZ_REVIEWER_TEAMS:-}"
ALLOW_SELF_REVIEW="${LZ_ALLOW_SELF_REVIEW:-0}"
AUTO_APPROVE=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="$2"; shift 2 ;;
    --billing-account) BILLING="$2"; shift 2 ;;
    --github-owner) GH_OWNER="$2"; shift 2 ;;
    --github-repo) GH_REPO="$2"; shift 2 ;;
    --github-token) GH_TOKEN_GATE="$2"; shift 2 ;;
    --reviewer-users) REVIEWER_USERS="$2"; shift 2 ;;
    --reviewer-teams) REVIEWER_TEAMS="$2"; shift 2 ;;
    --allow-self-review) ALLOW_SELF_REVIEW=1; shift ;;
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

# --- 4b. terraform: reviewer gate on the GitHub environment ---------------
# The apply job deploys through the "landing-zone" GitHub environment. An
# environment with no required reviewers lets every push to main apply
# unattended — the deploy workflow's gate job fails closed in that case, so
# this step is what makes applies possible at all (and makes the documented
# two-human rule real).
if [[ -n "$GH_TOKEN_GATE" ]]; then
  # A gate token with no reviewers would make tf-gate fail its
  # precondition after the (slow) GCP half of bootstrap — reject it here,
  # before anything runs.
  if [[ -z "$REVIEWER_USERS" && -z "$REVIEWER_TEAMS" ]]; then
    echo "ERROR: --github-token given but no reviewers: pass --reviewer-users alice,bob" >&2
    echo "       (or --reviewer-teams team-slug; solo: --reviewer-users <you> --allow-self-review)" >&2
    exit 1
  fi
  say "Configuring the landing-zone environment gate (reviewers)"
  # tf-gate is a sibling of tf/ — resolve it from TF_DIR, not $0, because we
  # already cd'd and $0 may be relative to the original working directory.
  GATE_DIR="$(cd "$TF_DIR/../tf-gate" && pwd)"

  # --reviewer-users alice,bob becomes a proper HCL list ["alice","bob"]:
  # quote each login, then join with commas.
  hcl_list() {
    local items="$1" quoted=""
    IFS=',' read -ra parts <<<"$items"
    for p in "${parts[@]}"; do
      [[ -n "$p" ]] || continue
      quoted+="${quoted:+,}\"$p\""
    done
    printf '[%s]' "$quoted"
  }
  REVIEWER_USERS_ARG=()
  [[ -n "$REVIEWER_USERS" ]] && REVIEWER_USERS_ARG=(-var "reviewer_users=$(hcl_list "$REVIEWER_USERS")")
  REVIEWER_TEAMS_ARG=()
  [[ -n "$REVIEWER_TEAMS" ]] && REVIEWER_TEAMS_ARG=(-var "reviewer_teams=$(hcl_list "$REVIEWER_TEAMS")")
  SELF_REVIEW_ARG=(-var "prevent_self_review=true")
  [[ $ALLOW_SELF_REVIEW -eq 1 ]] && SELF_REVIEW_ARG=(-var "prevent_self_review=false")

  # The token is passed as an environment variable, not -var, so it does not
  # land in the plan file, the shell history, or a tfvars file. Similarly,
  # GATE_DIR runs in a subshell so the bootstrap dir stays current for the
  # terraform output calls in section 5.
  (
    cd "$GATE_DIR"
    export TF_VAR_github_token="$GH_TOKEN_GATE"
    terraform init -input=false \
      -backend-config="bucket=$BUCKET" \
      -backend-config="prefix=landing-zone/github-gate"
    terraform apply -input=false "${APPROVE_ARGS[@]}" \
      -var "github_owner=$GH_OWNER" \
      -var "github_repo=$GH_REPO" \
      "${REVIEWER_USERS_ARG[@]}" \
      "${REVIEWER_TEAMS_ARG[@]}" \
      "${SELF_REVIEW_ARG[@]}"
  )
else
  echo >&2
  echo "WARNING: --github-token not given — the landing-zone environment was" >&2
  echo "NOT configured with required reviewers. The deploy workflow's gate job" >&2
  echo "will fail every apply until you do one of:" >&2
  echo "  - re-run bootstrap with --github-token and --reviewer-users (or teams)" >&2
  echo "  - Settings → Environments → landing-zone → add Required reviewers" >&2
fi

# --- 5. instructions ---------------------------------------------------------
WIF_PROVIDER="$(terraform output -raw wif_provider)"
STATE_BUCKET_OUT="$(terraform output -raw state_bucket)"

if [[ -n "$GH_TOKEN_GATE" && $ALLOW_SELF_REVIEW -eq 1 ]]; then
  ALLOW_SELF_REVIEW_MSG=" (you will approve your own pushes — --allow-self-review was used)"
else
  ALLOW_SELF_REVIEW_MSG=""
fi

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
   1. Push to main. The deploy workflow applies stages 01→02→03→10 —
      the apply waits for an approval by the landing-zone environment
      reviewers${ALLOW_SELF_REVIEW_MSG}.
   2. Edit catalogs/groups.yaml (your domain) and catalogs/*.yaml to taste.
   3. (Recommended) Enable branch protection on main: require the ci and
      deploy checks and a PR review — the environment gate alone cannot
      stop a direct push that edits the workflows themselves.
=====================================================================
EOF
