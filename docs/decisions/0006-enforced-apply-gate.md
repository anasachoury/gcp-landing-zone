# ADR-0006: Enforce the apply gate in code, fail closed in the pipeline

- Status: accepted
- Date: 2026-11-13

## Context

The deploy workflow's apply job references the `landing-zone` GitHub
environment, and the README's security model claims "every apply is
gated". But referencing an environment gates nothing by itself: an
environment without protection rules is a no-op — a push to main runs
the apply immediately, and the job's own comment admitted it "runs
without a gate" until a human remembers to add reviewers in repository
settings. The protection was a manual, out-of-band, optional step:
exactly the kind of step that gets skipped on day one and forgotten
forever, while the README keeps selling the two-human rule.

The same applies to any future drift: nothing noticed if the reviewers
were removed from the environment later.

## Decision

Three layers, so the documented rule is true by construction:

1. **Provisioned, not remembered** — `bootstrap/tf-gate` manages the
   `landing-zone` environment through the `integrations/github` provider
   (`github_repository_environment`): required reviewers
   (`--reviewer-users` / `--reviewer-teams`), `prevent_self_review =
   true` (whoever pushed cannot approve), `can_admins_bypass = false`.
   The module refuses to apply with zero reviewers. It runs as part of
   `bootstrap.sh --github-token`, which also prints a loud warning when
   the flag is omitted.
2. **Fail closed** — the deploy workflow has a `gate` job that runs
   before `apply` (`apply.needs: gate`) on every push to main. It reads
   the environment's protection rules through the REST API with the
   job's own `GITHUB_TOKEN` and fails the run if there is no
   `required_reviewers` rule. Ungated applies are blocked even for
   people who never ran the tf-gate module — and if reviewers are
   removed later, the next apply stops instead of sailing through.
3. **Solo-operator escape hatch** — `--allow-self-review` sets
   `prevent_self_review = false` with the operator as sole reviewer.
   The apply still needs a click, but the same human can provide it.
   Documented as a deliberate trade-off, not a default.

`prevent_self_review` and `can_admins_bypass` stay Terraform variables
with safe defaults rather than hardcoded `true`: a solo repository
owner who hardcodes `prevent_self_review` with themselves as the only
reviewer deadlocks every apply permanently (nobody else can approve),
and that failure mode is worse than a documented downgrade.

## Consequences

- First bootstrap without `--github-token` still succeeds, but every
  apply then fails in the `gate` job with instructions — the ungated
  state cannot pass silently.
- The pipeline needs one more permission surface: reading environment
  protection rules (plain repository read access; no `environments`
  GITHUB_TOKEN scope exists).
- The gate job protects against a missing or unconfigured environment;
  it cannot stop an attacker with direct push access from rewriting the
  workflow itself — that is branch protection's job (listed as a
  guardrail in docs/pipeline.md, ADR-0001 territory).
- tf-gate state joins the shared state bucket under
  `landing-zone/github-gate`; reviewer changes are ordinary Terraform
  changes from then on, reviewed like everything else.
