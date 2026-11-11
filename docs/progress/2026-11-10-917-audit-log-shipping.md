# Progress: nwlnexus/olympus-sdk#917 CA3: audit log shipping and alert (olympus-gitops half)

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/917`
- **Branch / worktree:** `feat/917-audit-log-shipping` (olympus-gitops)
- **Session:** `personal-olympus-sdk-917`
- **Started:** 2026-11-10 · **Turn cap:** 60
- **Draft PR:** not yet

## Goal

```text
/goal #917 Done-when: the render test and CI pass in both repos; all five servers write the audit log; a read made through the Kubernetes MCP server (or any ServiceAccount read until it is live) appears in Loki; the alert rule loads. Checks: gh pr checks <pr> all pass in each repo; on each server sudo test -s /var/lib/rancher/k3s/server/logs/audit.log prints ok and the file is growing; a LogQL query on the audit stream returns at least one entry; the Loki ruler lists the rule group. Progress file is current until its removal. Or stop after 60 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `gh pr checks <pr>` in olympus-infra and olympus-gitops | all pass | olympus-infra#136: PASS, merged `2cc8d5a` | |
| 2 | on each server: `sudo test -s /var/lib/rancher/k3s/server/logs/audit.log && echo ok` | `ok`, modification time recent | not run (staging blocked, see Blocked-on) | |
| 3 | LogQL on the audit stream after a ServiceAccount read | at least one entry | not run | |
| 4 | Loki ruler lists the rule group | present, no error | not run | |

## Plan

Blast radius: no index (manifests only).

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | olympus-infra role, play, policy (PR #136) | opus + fable review | subagent | done |
| 2 | Stage on the canary, then the other servers; restarts | owner | — | blocked |
| 3 | Second filelog receiver on the log DaemonSet; Loki rule and rule test | opus | subagent | doing |
| 4 | Review, verifier, merge | fable, opus | main + subagent | todo |
| 5 | Verify checks 2 to 4; close | fable | main | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 2026-11-10 | `scripts/k3s-health-gate.sh` (olympus-infra) | 0 | `RESULT: PASS (22 checks)` | |
| 2026-11-10 | push play on the canary, `--check --diff` | 0 | `ok=11 changed=3 failed=0` | |

## Decisions

- 2026-11-10: The log collector change must not affect existing container log shipping. Why: every pod log goes through this DaemonSet.
- 2026-11-10: The audit stream gets its own service name and no pod attributes. Why: it is a host file, not a container log, and the alert rule selects on that name.

## Blocked-on

- Staging on servers: the real run of the push play was denied in the session by the auto-mode classifier, rule `Protected-Scope IaC Apply`. The owner runs it or allows it. Restarts are the owner's in any case.

## Next

1. Wait for the manifests subagent; review.
