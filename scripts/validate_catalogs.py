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


def check_list(path, where, value, what):
    if not isinstance(value, list) or not value:
        err(path, where, f"{what} must be a non-empty list")


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
    if g.get("email", "").endswith("example.com"):
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

# --- org-policies.yaml ---
_, policies_doc = load("org-policies.yaml")
policies = policies_doc.get("policies", [])
seen_constraints = set()
for p in policies:
    where = p.get("constraint", "?")
    if not str(p.get("constraint", "")).startswith("constraints/"):
        err("org-policies.yaml", where, "constraint must start with 'constraints/'")
        continue
    if p["constraint"] in seen_constraints:
        err("org-policies.yaml", where, f"duplicate constraint {p['constraint']!r}")
    seen_constraints.add(p["constraint"])
    ptype = p.get("type")
    if ptype == "boolean":
        if not isinstance(p.get("enforce"), bool):
            err("org-policies.yaml", where, "boolean policy needs enforce: true|false")
    elif ptype == "list":
        has_mode = p.get("enforcement") in ("allow", "deny")
        has_values = bool(p.get("allowed_values") or p.get("denied_values"))
        if has_mode == has_values:
            err(
                "org-policies.yaml",
                where,
                "list policy needs exactly one of enforcement: allow|deny "
                "or allowed_values/denied_values",
            )
    else:
        err("org-policies.yaml", where, f"type must be boolean or list, got {ptype!r}")
    for f in p.get("exceptions", []):
        if f not in folder_names:
            err("org-policies.yaml", where, f"exception references unknown folder {f!r}")

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

# --- report ---
if errors:
    print(f"Catalog validation FAILED — {len(errors)} problem(s):")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

print(
    f"Catalogs OK: {len(folders_doc)} folders, {len(groups_doc_groups)} groups, "
    f"{len(policies)} org policies, {len(net_doc.get('subnets', []))} subnets, "
    f"{len(projects)} projects."
)
