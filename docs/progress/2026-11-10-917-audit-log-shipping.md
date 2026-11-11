# Progress: nwlnexus/olympus-sdk#917 CA3: audit log shipping and alert (olympus-gitops half)

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/917`
- **Branch / worktree:** `feat/917-audit-log-shipping` (olympus-gitops)
- **Session:** `personal-olympus-sdk-917`
- **Started:** 2026-11-10 · **Turn cap:** 60
- **Draft PR:** `https://github.com/nwlnexus/olympus-gitops/pull/260`

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
| 2 | Stage on the canary, then the other servers; restarts | owner | — | doing (canary staged and restarted by the owner; policy fix olympus-infra#138 merged, canary to be re-staged and restarted) |
| 3 | Audit-only collector `otel-audit` on the servers; Loki rules | opus | subagent | done (9fca7a0, 47ab073) |
| 4 | Review, verifier, merge | fable, opus | main + subagent | todo |
| 5 | Verify checks 2 to 4; close | fable | main | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 2026-11-10 | `scripts/k3s-health-gate.sh` (olympus-infra) | 0 | `RESULT: PASS (22 checks)` | |
| 2026-11-10 | push play on the canary, `--check --diff` | 0 | `ok=11 changed=3 failed=0` | |
| 2026-11-11 | owner ran the push play on the canary; `systemctl restart k3s` | 0 | journal: `Running kube-apiserver ... --audit-log-path=... --audit-policy-file=...`; `/readyz` ok; log non-empty and growing | |
| 2026-11-11 | `scripts/k3s-health-gate.sh` after the canary restart | 0 | `RESULT: PASS (22 checks)` | |
| 2026-11-11 | read-only summary of the canary's audit log (no bodies printed) | 0 | 274 lines in 6 min, all `Metadata`; about 35 of 40 lines per minute are `system:admin get leases kube-system/plndr-cp-lock` (kube-vip) | |
| 2026-11-11 | olympus-infra#138 (drop the two VIP election Leases by name), claim-verifier PASS, merged | 0 | `c0f4a91` | |
| 2026-11-11 | subagent: `helm template` chart 0.158.0 of `otel-audit`; local otelcol-contrib 0.155.0 + Loki 3.7.9 end to end; `lokitool rules check`/`lint`; yamllint; kustomize build + kubeconform | 0 | DaemonSet only (no RBAC, no Service); 14 lines in, 14 in Loki across a collector restart; 3 rules fire for the right users only; `validate` green on the PR | 47ab073 |
| 2026-11-11 | `git diff origin/main -- clusters/olympus/otel-collector/helmrelease-logs.yaml \| wc -c` | 0 | `0` | 47ab073 |

## Decisions

- 2026-11-10: The log collector change must not affect existing container log shipping. Why: every pod log goes through this DaemonSet.
- 2026-11-10: The audit stream gets its own service name and no pod attributes. Why: it is a host file, not a container log, and the alert rule selects on that name.
- 2026-11-11: A separate audit-only collector, not a second receiver on the existing log DaemonSet. Why: the existing collector runs as uid 10001 and cannot read the root 0700 audit directory; making it root would put a root collector with API access on all nine nodes. The new one is root with all capabilities dropped, no API access, read-only mount, on the five servers only.
- 2026-11-11: `disableWait` on the new HelmRelease, and merge this PR only after the audit directory is staged on all five servers. Why: with `type: Directory`, pods stay in ContainerCreating on a server without the directory, which would fail a Helm wait and trip the health gate's pod check during the rollout.
- 2026-11-11: `K8sAuditLogSilent` left out; follow-up after rollout.
- 2026-11-11: Two commit trailers were rewritten (force-with-lease) to the standard co-author line.

## Blocked-on

- Staging and restarts are run by the owner (the session's real run of the push play was denied by the auto-mode classifier, rule `Protected-Scope IaC Apply`). Waiting: canary re-stage and restart with the fixed policy; then the other four servers.

## Next

1. After the canary restart: health gate, re-sample the audit log (VIP lease lines gone).
2. Owner stages and restarts the other four servers, one at a time, VIP holder last.
3. Then: claim-verifier on this PR, remove this file, ready, automerge; check the DaemonSet, Loki stream and ruler (checks 2 to 4).
