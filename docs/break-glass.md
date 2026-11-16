# Break-glass

Emergency access for the day the pipeline cannot help you: the pipeline
service account is gone, the organization IAM policy is broken, an org policy
is blocking the repair, or nobody in `lz-admins` can authenticate.

Two accounts, one group, one alert. That is the whole design.

## What exists

| Piece | Where | Notes |
| --- | --- | --- |
| Two emergency accounts | `catalogs/groups.yaml` → `break_glass.accounts` | Ordinary Cloud Identity users. **No standing GCP role.** |
| `break-glass` group | `catalogs/groups.yaml` | Created in Cloud Identity, kept **empty** in steady state |
| Repair roles on the group | `catalogs/groups.yaml` → `bindings` | `resourcemanager.organizationAdmin`, `orgpolicy.policyAdmin`, `logging.viewer` — enough to fix IAM and policy, nothing that can read data |
| Activity alert | `stages/03-security` | Any API call by either account emails `security-admins` immediately |
| Change alert | `stages/03-security` | Any org-level `SetIamPolicy` or org policy change also emails `security-admins` |

Because the roles are bound to the *group* and the group is empty, the accounts
have no power until someone deliberately adds one to the group. Adding that
membership is the moment of "breaking the glass", and it is the thing the
alerting and the review afterwards are built around.

## What it is not

- **Not a bypass of org policy.** Google Cloud org policy has no principal
  exceptions. If a constraint blocks the repair, you lift the constraint in
  `catalogs/org-policies.yaml` through a PR — or, if the pipeline is the thing
  that is broken, you use the break-glass account to change it in the console
  and codify it immediately afterwards.
- **Not a shared password.** Two people, two accounts, credentials held
  offline with dual control (sealed envelope in a safe, or a password manager
  with two approvers). If both are in the same vault that one person can open,
  you have one account with extra steps.
- **Not for routine work.** If a break-glass account is used for a normal
  change, the alert fires, the review finds it, and the answer is "that should
  have been a PR".

## One-time setup

Do this once, from an org admin's machine, before you need it.

1. **Create the two accounts** in Cloud Identity (Directory → Users). Use a
   name that is obviously an emergency identity, e.g.
   `emergency-1@your-domain.com`. Do not give them a mailbox that anyone reads
   daily.

2. **Give them super admin, and nothing else.** In the Admin console, assign
   the `Super Admin` role to both — that is a Cloud Identity role, not a GCP
   IAM role, and it is what lets them get back into the console if IAM is
   broken. They must not be members of `lz-admins`, `network-admins` or
   `security-admins`.

3. **Enforce strong MFA** on both, and store the credentials offline with dual
   control. Rotate them after every use.

4. **Create the group** (the landing zone binds roles to it, it does not create
   it):

   ```bash
   gcloud identity groups create break-glass@your-domain.com \
     --organization=CUSTOMER_ID \
     --display-name="Break Glass (emergency access)" \
     --group-type=security
   ```

5. **Put the account emails in the catalog** and merge:

   ```yaml
   break_glass:
     accounts:
       - emergency-1@your-domain.com
       - emergency-2@your-domain.com
   ```

   CI rejects placeholders and fewer than two accounts.

6. **Verify the alert actually fires.** Sign in as `emergency-1`, run one
   harmless read, and confirm the "Break-glass account in use" alert reaches
   `security-admins` within a couple of minutes:

   ```bash
   gcloud projects list --limit=1
   ```

   An alert you have never seen fire is a hypothesis, not a control.

## Using it

1. **Declare.** Post in the incident channel: who is taking the account, why,
   and what they are about to change. Two people should agree — one to act, one
   to watch.

2. **Add the account to the group** (from an account that still has admin, or
   from the Admin console):

   ```bash
   gcloud identity groups memberships add \
     --group-email=break-glass@your-domain.com \
     --member-email=emergency-1@your-domain.com
   ```

   Membership takes a few minutes to reach IAM. Check with
   `gcloud projects get-iam-policy` on a project, or just retry the action.

3. **Sign in as the emergency account** and do the minimum. Fix the IAM
   binding, restore the service account, lift the policy — nothing else. Do not
   create resources, do not "tidy up", do not leave the session open.

4. **Remove the membership** as soon as the repair is done:

   ```bash
   gcloud identity groups memberships delete \
     --group-email=break-glass@your-domain.com \
     --member-email=emergency-1@your-domain.com
   ```

5. **Codify the fix.** Whatever you changed by hand goes into a PR the same
   day: `catalogs/org-policies.yaml`, `catalogs/groups.yaml`, or the relevant
   stage. The nightly drift job will open an issue anyway — close it by making
   the catalogs true, not by ignoring it.

6. **Review within 48 hours.** Security admins pull the audit trail for both
   accounts from BigQuery (or the `audit-logs` bucket), confirm every action is
   accounted for in the incident record, and rotate the credentials.

```sql
-- everything the emergency accounts did, from the audit export
SELECT timestamp, protopayload_auditlog.authenticationInfo.principalEmail AS principal,
       protopayload_auditlog.methodName AS method,
       protopayload_auditlog.resourceName AS resource
FROM `PROJECT.audit_export.cloudaudit_googleapis_com_activity_*`
WHERE protopayload_auditlog.authenticationInfo.principalEmail LIKE 'emergency-%'
ORDER BY timestamp DESC
```

## Rehearsing

Once a quarter, on purpose, during business hours:

1. Add `emergency-1` to the group.
2. Have it run one read-only command.
3. Confirm the alert arrived and the BigQuery export contains the call.
4. Remove the membership.

A break-glass path that has never been walked is a break-glass path that does
not work. The rehearsal is also the cheapest possible test of the alerting.
