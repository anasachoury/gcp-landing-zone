#!/usr/bin/env python3
"""Validate the landing zone catalogs.

Checks the YAML under catalogs/ for schema and consistency errors before
Terraform ever runs: uniqueness, cross-references between catalogs, CIDR
overlaps, and identifier length limits GCP enforces.

Exit code 0 = all good, 1 = problems found (printed with file and key).
"""

import ipaddress
import os
import re
import sys

import yaml

CATALOG_DIR = os.path.join(os.path.dirname(__file__), "..", "catalogs")

ENV_CODES = {
    "development": "dev",
    "non-production": "nonprod",
    "production": "prod",
    "sandbox": "sbx",
}
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ROLE_RE = re.compile(r"^roles/[a-zA-Z0-9._]+$")
LABEL_KEY_RE = re.compile(r"^[a-z][a-z0-9_-]{0,62}$")
LABEL_VALUE_RE = re.compile(r"^[a-z0-9_-]{0,63}$")
TAG_KEY_RE = re.compile(r"^[a-z][a-z0-9_-]{0,62}$")
TAG_VALUE_RE = re.compile(r"^[a-z0-9_-]{1,63}$")
BUCKET_ID_RE = re.compile(r"^[a-z][a-z0-9-]{2,62}$")
DATASET_ID_RE = re.compile(r"^[A-Za-z0-9_]{1,1024}$")
TOPIC_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9._~+%-]{2,254}$")
SERVICE_RE = re.compile(r"^[a-z0-9-]+\.googleapis\.com$")
MEMBER_RE = re.compile(r"^(user|group|serviceAccount|domain):")

# Constraints that accept only allowed_values, never denied_values.
ALLOW_ONLY = {
    "constraints/iam.allowedPolicyMemberDomains",
    "constraints/iam.serviceAccountKeyExpiryHours",
}

# The fixed set of durations iam.serviceAccountKeyExpiryHours accepts.
KEY_EXPIRY_VALUES = {"1h", "8h", "24h", "168h", "336h", "720h", "1440h", "2160h"}

PROTOCOL_FORWARDING_VALUES = {"INTERNAL", "EXTERNAL"}

# List constraints whose values are resource paths; anything else there is a
# typo that would only surface as an apply-time API error.
PATH_VALUE_CONSTRAINTS = {
    "constraints/compute.restrictVpcPeering",
    "constraints/compute.restrictSharedVpcSubnetworks",
}
PATH_PREFIXES = ("under:", "is:", "projects/", "folders/", "organizations/")

VALID_LOG_TYPES = {"ADMIN_READ", "DATA_READ", "DATA_WRITE"}

errors = []


def err(path, where, msg):
    errors.append(f"{path}: {where}: {msg}")


def load(name):
    path = os.path.join(CATALOG_DIR, name)
    try:
        with open(path, encoding="utf-8") as fh:
            return path, yaml.safe_load(fh) or {}
    except yaml.YAMLError as exc:
        err(path, "parse", f"invalid YAML: {exc}")
        return path, {}
    except FileNotFoundError:
        err(path, "load", "catalog file is missing")
        return path, {}


def check_list(path, where, value, what):
    if not isinstance(value, list) or not value:
        err(path, where, f"{what} must be a non-empty list")


def is_placeholder(value):
    return str(value).lower().endswith("example.com")


# --- folders.yaml ---
_, folders_doc = load("folders.yaml")
folders_doc = folders_doc.get("folders", [])
folder_names = set()
for f in folders_doc:
    where = f.get("name", "?")
    if not isinstance(f.get("name"), str) or not f["name"]:
        err("folders.yaml", where, "folder needs a non-empty name")
        continue
    if f["name"] in folder_names:
        err("folders.yaml", where, f"duplicate folder name {f['name']!r}")
    folder_names.add(f["name"])
    if not f.get("display_name"):
        err("folders.yaml", where, "missing display_name")

# --- groups.yaml ---
_, groups_doc = load("groups.yaml")
groups_doc_groups = groups_doc.get("groups", [])
group_ids, group_emails = {}, set()
for g in groups_doc_groups:
    where = g.get("id", "?")
    if not g.get("id"):
        err("groups.yaml", where, "group needs an id")
        continue
    if g["id"] in group_ids:
        err("groups.yaml", where, f"duplicate group id {g['id']!r}")
    if not g.get("email") or not EMAIL_RE.match(g["email"]):
        err("groups.yaml", where, f"invalid or missing email {g.get('email')!r}")
    elif g["email"] in group_emails:
        err("groups.yaml", where, f"duplicate email {g['email']!r}")
    if is_placeholder(g.get("email", "")):
        err(
            "groups.yaml",
            where,
            "example.com placeholder left in — set your identity domain",
        )
    group_ids[g["id"]] = g.get("email")
    group_emails.add(g.get("email"))

for b in groups_doc.get("bindings", []):
    where = f"binding for {b.get('group')!r}"
    if b.get("group") not in group_ids:
        err("groups.yaml", where, f"unknown group id {b.get('group')!r}")
        continue
    parent = b.get("parent", "")
    if parent == "organization":
        pass
    elif parent.startswith("folder:"):
        folder = parent.split(":", 1)[1]
        if folder not in folder_names:
            err("groups.yaml", where, f"unknown folder {folder!r} in parent")
    else:
        err("groups.yaml", where, "parent must be 'organization' or 'folder:<name>'")
    roles = b.get("roles", [])
    check_list("groups.yaml", where, roles, "roles")
    for r in roles:
        if not ROLE_RE.match(r):
            err("groups.yaml", where, f"role {r!r} does not look like roles/...")

# --- groups.yaml: break-glass ---
break_glass_accounts = []
if "break_glass" in groups_doc:
    bg = groups_doc.get("break_glass") or {}
    accounts = bg.get("accounts") or []
    if not isinstance(accounts, list) or len(accounts) < 2:
        err(
            "groups.yaml",
            "break_glass",
            "needs at least two accounts — one is not break-glass, it is a "
            "single point of failure",
        )
    seen_accounts = set()
    for a in accounts:
        if not EMAIL_RE.match(str(a)):
            err("groups.yaml", "break_glass", f"invalid account email {a!r}")
            continue
        if is_placeholder(a):
            err(
                "groups.yaml",
                "break_glass",
                "example.com placeholder left in — set your emergency accounts",
            )
        if a in seen_accounts:
            err("groups.yaml", "break_glass", f"duplicate account {a!r}")
        seen_accounts.add(a)
        break_glass_accounts.append(a)
    if "break-glass" not in group_ids:
        err(
            "groups.yaml",
            "break_glass",
            "accounts are declared but there is no group with id 'break-glass'",
        )
    elif not any(
        b.get("group") == "break-glass" for b in groups_doc.get("bindings", [])
    ):
        err(
            "groups.yaml",
            "break_glass",
            "the break-glass group has no role bindings — it could not repair anything",
        )

# --- org-policies.yaml ---
_, policies_doc = load("org-policies.yaml")
policies = policies_doc.get("policies", [])
seen_constraints = set()
allowed_member_domains = []
for p in policies:
    where = p.get("constraint", "?")
    if not str(p.get("constraint", "")).startswith("constraints/"):
        err("org-policies.yaml", where, "constraint must start with 'constraints/'")
        continue
    constraint = p["constraint"]
    scope = p.get("folder") or "organization"
    scoped_key = f"{scope}|{constraint}"
    if scoped_key in seen_constraints:
        err(
            "org-policies.yaml",
            where,
            f"duplicate constraint {constraint!r} for scope {scope!r}",
        )
    seen_constraints.add(scoped_key)

    if p.get("folder") is not None and p["folder"] not in folder_names:
        err(
            "org-policies.yaml",
            where,
            f"folder {p['folder']!r} is not in folders.yaml",
        )
    if p.get("folder") is not None and p.get("exceptions"):
        err(
            "org-policies.yaml",
            where,
            "a folder-scoped policy cannot also list exceptions — put the "
            "policy at organization level and except the folder instead",
        )

    ptype = p.get("type")
    allowed = p.get("allowed_values") or []
    denied = p.get("denied_values") or []
    if ptype == "boolean":
        if not isinstance(p.get("enforce"), bool):
            err("org-policies.yaml", where, "boolean policy needs enforce: true|false")
        if p.get("enforcement") or allowed or denied:
            err(
                "org-policies.yaml",
                where,
                "boolean policy takes enforce only — no enforcement/values",
            )
    elif ptype == "list":
        has_mode = p.get("enforcement") in ("allow", "deny")
        has_values = bool(allowed or denied)
        if has_mode == has_values:
            err(
                "org-policies.yaml",
                where,
                "list policy needs exactly one of enforcement: allow|deny "
                "or allowed_values/denied_values",
            )
        if has_mode and p.get("enforce") is not None:
            err(
                "org-policies.yaml",
                where,
                "list policy takes enforcement, not enforce",
            )
    else:
        err("org-policies.yaml", where, f"type must be boolean or list, got {ptype!r}")

    if constraint in ALLOW_ONLY and denied:
        err(
            "org-policies.yaml",
            where,
            f"{constraint} accepts allowed_values only — denied_values are "
            "not supported by the API",
        )

    # --- constraint-specific value checks ---
    if constraint == "constraints/iam.allowedPolicyMemberDomains":
        if not allowed:
            err(
                "org-policies.yaml",
                where,
                "domain-restricted sharing needs at least one allowed value "
                "(your domain or Cloud Identity customer id)",
            )
        for v in allowed:
            bare = v[3:] if str(v).startswith("is:") else str(v)
            if is_placeholder(bare):
                err(
                    "org-policies.yaml",
                    where,
                    "example.com placeholder left in — set your identity domain",
                )
            if re.fullmatch(r"C[0-9a-z]{6,}", bare):
                continue  # a customer id; domains are cross-checked below
            if not re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,}", bare.lower()):
                err(
                    "org-policies.yaml",
                    where,
                    f"{v!r} is neither a domain nor a Cloud Identity customer id",
                )
            else:
                allowed_member_domains.append(bare.lower())

    if constraint == "constraints/iam.serviceAccountKeyExpiryHours":
        if len(allowed) != 1:
            err(
                "org-policies.yaml",
                where,
                "exactly one allowed value may be set (the API rejects more)",
            )
        for v in allowed:
            if v not in KEY_EXPIRY_VALUES:
                err(
                    "org-policies.yaml",
                    where,
                    f"{v!r} is not one of {sorted(KEY_EXPIRY_VALUES)}",
                )

    if constraint == "constraints/compute.restrictProtocolForwardingCreationForTypes":
        for v in allowed + denied:
            if v not in PROTOCOL_FORWARDING_VALUES:
                err(
                    "org-policies.yaml",
                    where,
                    f"{v!r} must be INTERNAL or EXTERNAL",
                )

    if constraint in PATH_VALUE_CONSTRAINTS:
        for v in allowed + denied:
            if not str(v).startswith(PATH_PREFIXES):
                err(
                    "org-policies.yaml",
                    where,
                    f"{v!r} must be a resource path (under:organizations/…, "
                    "under:projects/…, is:…)",
                )

    if constraint == "constraints/gcp.restrictNonCmekServices":
        if not denied:
            err(
                "org-policies.yaml",
                where,
                "CMEK enforcement lists the services that must use CMEK in "
                "denied_values",
            )
        for v in denied:
            if not SERVICE_RE.match(str(v)):
                err("org-policies.yaml", where, f"{v!r} does not look like a service")

    for f in p.get("exceptions", []):
        if f not in folder_names:
            err("org-policies.yaml", where, f"exception references unknown folder {f!r}")

# Domain-restricted sharing must actually cover the identities in groups.yaml,
# otherwise the first apply that grants a role to a group fails — or worse,
# succeeds because the policy was left wide open.
if allowed_member_domains:
    for email in sorted(e for e in group_emails if e):
        domain = str(email).split("@")[-1].lower()
        if domain not in allowed_member_domains:
            err(
                "org-policies.yaml",
                "constraints/iam.allowedPolicyMemberDomains",
                f"group {email} is outside the allowed domains "
                f"{sorted(allowed_member_domains)} — the grant will be rejected",
            )

# --- audit-logs.yaml ---
_, audit_doc = load("audit-logs.yaml")
audit_cfg = audit_doc.get("audit_config") or {}
all_services = audit_cfg.get("all_services") or {}
if not all_services:
    err("audit-logs.yaml", "audit_config.all_services", "is required")
for lt in all_services.get("log_types", []) or []:
    if lt not in VALID_LOG_TYPES:
        err(
            "audit-logs.yaml",
            "audit_config.all_services",
            f"invalid log type {lt!r} (ADMIN_READ, DATA_READ, DATA_WRITE)",
        )

seen_services = set()
for s in audit_cfg.get("services", []) or []:
    svc = s.get("service")
    where = str(svc)
    if not svc or not SERVICE_RE.match(str(svc)):
        err("audit-logs.yaml", where, f"invalid service name {svc!r}")
        continue
    if svc in seen_services:
        err("audit-logs.yaml", where, f"duplicate service {svc!r}")
    seen_services.add(svc)
    types = s.get("log_types") or []
    check_list("audit-logs.yaml", where, types, "log_types")
    for lt in types:
        if lt not in VALID_LOG_TYPES:
            err("audit-logs.yaml", where, f"invalid log type {lt!r}")
    for m in s.get("exempted_members", []) or []:
        if not MEMBER_RE.match(str(m)):
            err(
                "audit-logs.yaml",
                where,
                f"exempted member {m!r} must start with user:/group:/serviceAccount:/domain:",
            )

buckets = audit_doc.get("buckets") or []
if not buckets:
    err("audit-logs.yaml", "buckets", "needs at least one bucket")
seen_buckets = set()
for b in buckets:
    bid = b.get("id")
    where = str(bid)
    if not bid or not BUCKET_ID_RE.match(str(bid)):
        err("audit-logs.yaml", where, f"invalid bucket id {bid!r}")
        continue
    if bid in seen_buckets:
        err("audit-logs.yaml", where, f"duplicate bucket id {bid!r}")
    seen_buckets.add(bid)
    if not b.get("filter"):
        err("audit-logs.yaml", where, "needs a filter — an empty sink copies everything")
    retention = b.get("retention_days")
    if not isinstance(retention, int) or retention < 1:
        err("audit-logs.yaml", where, "retention_days must be a positive integer")
    if not b.get("description"):
        err("audit-logs.yaml", where, "needs a description (it labels the sink)")

exports = audit_doc.get("exports") or {}
if "audit-logs" not in seen_buckets:
    err(
        "audit-logs.yaml",
        "buckets",
        "the 'audit-logs' bucket is required — stage 03-security scopes its "
        "log-based metrics to it",
    )
bq = exports.get("bigquery") or {}
if bq.get("enabled"):
    if not DATASET_ID_RE.match(str(bq.get("dataset", ""))):
        err("audit-logs.yaml", "exports.bigquery", "invalid dataset id")
    if not bq.get("filter"):
        err("audit-logs.yaml", "exports.bigquery", "needs a filter")
    if not bq.get("location"):
        err("audit-logs.yaml", "exports.bigquery", "needs a location (e.g. EU)")
ps = exports.get("pubsub") or {}
if ps.get("enabled"):
    if not TOPIC_RE.match(str(ps.get("topic", ""))):
        err("audit-logs.yaml", "exports.pubsub", "invalid topic name")
    if not ps.get("filter"):
        err("audit-logs.yaml", "exports.pubsub", "needs a filter")

# --- tags.yaml ---
_, tags_doc = load("tags.yaml")
tag_keys = tags_doc.get("keys") or []
tag_values = {}
seen_keys = set()
for k in tag_keys:
    short = k.get("short_name")
    where = str(short)
    if not short or not TAG_KEY_RE.match(str(short)):
        err("tags.yaml", where, f"invalid tag key short_name {short!r}")
        continue
    if short in seen_keys:
        err("tags.yaml", where, f"duplicate tag key {short!r}")
    seen_keys.add(short)
    values = k.get("values") or []
    check_list("tags.yaml", where, values, "values")
    tag_values[short] = set()
    for v in values:
        if not TAG_VALUE_RE.match(str(v)):
            err("tags.yaml", where, f"invalid tag value {v!r}")
        if v in tag_values[short]:
            err("tags.yaml", where, f"duplicate tag value {v!r}")
        tag_values[short].add(v)

# --- networks.yaml ---
_, net_doc = load("networks.yaml")
net_doc = net_doc or {}
regions = set(net_doc.get("regions", []))
all_ranges = []
for s in net_doc.get("subnets", []):
    where = f"subnet {s.get('region')}/{s.get('name')}"
    if s.get("region") not in regions:
        err("networks.yaml", where, f"region {s.get('region')!r} not in regions list")
    for attr in ("ip_cidr_range",):
        try:
            net = ipaddress.ip_network(s[attr])
            all_ranges.append((where, net))
        except (ValueError, KeyError):
            err("networks.yaml", where, f"invalid or missing {attr}")
    for sec in s.get("secondary_ranges", []) or []:
        try:
            net = ipaddress.ip_network(sec["ip_cidr_range"])
            all_ranges.append((where + f"/{sec.get('range_name')}", net))
        except (ValueError, KeyError):
            err("networks.yaml", where, "invalid secondary range ip_cidr_range")
    if net_doc.get("vpc", {}).get("routing_mode") not in ("REGIONAL", "GLOBAL"):
        err("networks.yaml", "vpc", "routing_mode must be REGIONAL or GLOBAL")

for i in range(len(all_ranges)):
    for j in range(i + 1, len(all_ranges)):
        (wa, na), (wb, nb) = all_ranges[i], all_ranges[j]
        if na.overlaps(nb):
            err(
                "networks.yaml",
                "subnets",
                f"CIDR overlap between {wa} ({na}) and {wb} ({nb})",
            )

# --- projects.yaml ---
_, projects_doc = load("projects.yaml")
projects = projects_doc.get("projects", [])
prefix = os.environ.get("LZ_PREFIX", "lz")
seen_keys, seen_ids = set(), set()
for p in projects:
    app, env = p.get("app"), p.get("environment")
    where = f"{app}/{env}"
    if not app or not env:
        err("projects.yaml", "?", "project entry needs app and environment")
        continue
    if (app, env) in seen_keys:
        err("projects.yaml", where, "duplicate app/environment combination")
    seen_keys.add((app, env))
    if p.get("folder") not in folder_names:
        err("projects.yaml", where, f"unknown folder {p.get('folder')!r}")
    env_code = ENV_CODES.get(env, env[:4])
    project_id = f"{prefix}-{app}-{env_code}"
    if project_id in seen_ids:
        err("projects.yaml", where, f"duplicate derived project id {project_id!r}")
    seen_ids.add(project_id)
    if len(project_id) > 30:
        err(
            "projects.yaml",
            where,
            f"derived project id {project_id!r} exceeds 30 characters "
            "(shorten app/environment)",
        )
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}", project_id):
        err("projects.yaml", where, f"derived project id {project_id!r} is not a valid GCP id")
    check_list("projects.yaml", where, p.get("services"), "services")
    for svc in p.get("services", []):
        if not re.fullmatch(r"[a-z0-9.-]+", str(svc)):
            err("projects.yaml", where, f"service name {svc!r} looks invalid")
    svpc = p.get("shared_vpc", {}) or {}
    if svpc.get("attach"):
        for user in svpc.get("subnet_users", []) or []:
            if user not in group_ids and not EMAIL_RE.match(str(user)):
                err("projects.yaml", where, f"subnet_user {user!r} is neither a group id nor an email")
    for sa in p.get("service_accounts", []) or []:
        sa_id = f"{app}-{sa.get('id')}"
        if len(sa_id) > 28:
            err("projects.yaml", where, f"service account id {sa_id!r} exceeds 28 characters")
        for role in sa.get("roles", []):
            if not ROLE_RE.match(role):
                err("projects.yaml", where, f"service account role {role!r} does not look like roles/...")
    budget = p.get("budget", {})
    if budget and not isinstance(budget.get("amount"), (int, float)):
        err("projects.yaml", where, "budget.amount must be a number")
    for k, v in (p.get("labels") or {}).items():
        if not LABEL_KEY_RE.match(str(k)):
            err("projects.yaml", where, f"invalid label key {k!r}")
        if not LABEL_VALUE_RE.match(str(v)):
            err("projects.yaml", where, f"invalid label value {v!r} for key {k!r}")

    # Tag bindings: the factory binds environment for every project, and
    # data_classification when it is set. Both must exist in tags.yaml.
    if "environment" not in tag_values:
        err(
            "tags.yaml",
            "keys",
            "no 'environment' tag key — every project is tagged with one",
        )
    elif env not in tag_values["environment"]:
        err(
            "projects.yaml",
            where,
            f"environment {env!r} has no matching value under the "
            "'environment' tag key in tags.yaml",
        )
    dc = p.get("data_classification")
    if dc is not None:
        if "data-classification" not in tag_values:
            err(
                "tags.yaml",
                "keys",
                "project sets data_classification but there is no "
                "'data-classification' tag key",
            )
        elif dc not in tag_values["data-classification"]:
            err(
                "projects.yaml",
                where,
                f"data_classification {dc!r} is not a value of the "
                "'data-classification' tag key in tags.yaml",
            )

# --- report ---
if errors:
    print(f"Catalog validation FAILED — {len(errors)} problem(s):")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print(
    f"Catalogs OK: {len(folders_doc)} folders, {len(groups_doc_groups)} groups, "
    f"{len(policies)} org policies, {len(buckets)} log buckets, "
    f"{len(tag_keys)} tag keys, {len(net_doc.get('subnets', []))} subnets, "
    f"{len(projects)} projects."
)
