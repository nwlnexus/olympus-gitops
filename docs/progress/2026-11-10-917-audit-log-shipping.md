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
| 2 | on each server: `sudo test -s /var/lib/rancher/k3s/server/logs/audit.log && echo ok` | `ok`, modification time recent | PASS: all five servers restarted 2026-11-11 02:28 to 02:35 UTC, log non-empty on each, `/readyz` ok, no audit or policy error in the journal | |
| 3 | LogQL on the audit stream after a ServiceAccount read | at least one entry | not run | |
| 4 | Loki ruler lists the rule group | present, no error | not run | |

## Plan

Blast radius: no index (manifests only).

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | olympus-infra role, play, policy (PR #136) | opus + fable review | subagent | done |
| 2 | Stage on the canary, then the other servers; restarts | owner | — | done (owner staged all five; canary restarted by the owner; the other four restarted by the session with the owner's explicit approval, health gate before and after each) |
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
| 2026-11-11 | canary after re-stage and restart: read-only log summary | 0 | policy has 17 rules; 0 VIP lease lines since the restart; a request made as the agent identity is recorded | |
| 2026-11-11 | rolling restart of onode-030c31, onode-0312ce, onode-062caa, onode-0636e4: `scripts/k3s-health-gate.sh` before and after each | 0 | `RESULT: PASS (22 checks)` at every step; after the last: etcd leader onode-0314ac, VIP lease onode-030c31 | |
| 2026-11-11 | five servers, 3-minute steady-state sample (read-only) | 0 | 53, 18, 37, 4 and 2 lines per minute; all `Metadata`; about 250 MB per day cluster-wide | |
| 2026-11-11 | claim-verifier on this PR at 58fdf8d | - | `VERDICT: PASS`; notes: rules missed impersonated identities and fired on access reviews | 58fdf8d |
| 2026-11-11 | subagent at e3f45bc: `lokitool rules check` and `lint`; seeded local Loki matrix; yamllint; kustomize build + kubeconform | 0 | impersonation matched, access and token reviews excluded from the write rule, look-alike group not matched; `validate` green | e3f45bc |

## Decisions

- 2026-11-10: The log collector change must not affect existing container log shipping. Why: every pod log goes through this DaemonSet.
- 2026-11-10: The audit stream gets its own service name and no pod attributes. Why: it is a host file, not a container log, and the alert rule selects on that name.
- 2026-11-11: A separate audit-only collector, not a second receiver on the existing log DaemonSet. Why: the existing collector runs as uid 10001 and cannot read the root 0700 audit directory; making it root would put a root collector with API access on all nine nodes. The new one is root with all capabilities dropped, no API access, read-only mount, on the five servers only.
- 2026-11-11: `disableWait` on the new HelmRelease, and merge this PR only after the audit directory is staged on all five servers. Why: with `type: Directory`, pods stay in ContainerCreating on a server without the directory, which would fail a Helm wait and trip the health gate's pod check during the rollout.
- 2026-11-11: `K8sAuditLogSilent` left out; follow-up after rollout.
- 2026-11-11: Two commit trailers were rewritten (force-with-lease) to the standard co-author line.
- 2026-11-11: Audit volume (about 250 MB per day) is dominated by machine writes (a storage provisioner's endpoints election, the CI runner controller, metrics-server access reviews). Tune in a later policy change taken with the next planned server restart; not blocking.

## Blocked-on

- none

## Next

1. claim-verifier on this PR; remove this file; ready; automerge.
2. After Flux reconciles: DaemonSet 5/5, collector logs clean, audit stream in Loki (check 3), ruler lists the group (check 4); measure volume; close #917.
