# Progress: nwlnexus/olympus-gitops#295 arc: olympus-linux capped at 3 runners by topology spread; raise maxRunners to 6

- **Issue:** `https://github.com/nwlnexus/olympus-gitops/issues/295`
- **Branch / worktree:** `fix/295-arc-linux-spread-capacity` in `~/projects/personal/.worktrees/olympus-gitops-295`
- **Session:** `personal-olympus-gitops-295` on ai-agent-host (lane W5-G subagent); registry id `a23fe559-2626-442a-af6e-66dd243a2144`
- **Started:** 2026-11-22 16:25 UTC · **Turn cap:** 30
- **Draft PR:** not yet

## Goal

```text
/goal olympus-gitops#295 Done when: maxRunners 6 live; olympus-linux template has nodeTaintsPolicy Honor + amd64 affinity; no new topology-spread FailedScheduling for olympus-linux after the apply; quota sums consistent. Checks: kubectl -n arc-runners get pods -l olympus.io/ci-runner=true -o wide (>3 Running, an onode with 2, while queued); kubectl get pod <linux pod> jsonpath nodeTaintsPolicy = Honor; kubectl -n arc-runners get events --field-selector reason=FailedScheduling (no spread events after apply); quota.yaml sums. Or stop after 30 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `kubectl -n arc-runners get pods -l olympus.io/ci-runner=true -o wide` | >3 Running, one onode with 2 (while jobs queue) | not run | |
| 2 | `kubectl -n arc-runners get pods -l olympus.io/ci-runner=true -o jsonpath='{.items[0].spec.topologySpreadConstraints[0].nodeTaintsPolicy}'` | `Honor` | not run | |
| 3 | `kubectl -n arc-runners get events --field-selector reason=FailedScheduling` | no "topology spread" event for olympus-linux newer than the apply | not run | |
| 4 | quota.yaml: ci-runners = ci-runners-non-kvm + ci-runners-kvm (pods, cpu, memory) | sums match | not run | |

## Plan

Blast radius: no index (olympus-gitops has no GitNexus index on purpose, CLAUDE.md "GitNexus").

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Read headroom, Pending cause (read-only kubectl/ssh) | opus | main | done |
| 2 | Edit helmrelease-scale-set.yaml (spread Honor, amd64, maxRunners 6), quota.yaml, README | opus | main | done |
| 3 | PR, CI green, verifier, automerge | opus + sonnet verifier | main/subagent | todo |
| 4 | Flux apply, measure before/after | opus | main | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 16:18 | `kubectl -n arc-runners get events` | 0 | `FailedScheduling pod/olympus-linux-runner-6n6l2 0/9 nodes are available: 1 node(s) didn't match Pod's node affinity/selector, 3 node(s) didn't match pod topology spread constraints, 5 node(s) had untolerated taint(s)` | |
| 16:18 | `kubectl get nodes` labels/taints | 0 | `data-hub-vm <none> arm64 olympus.io/arch` (x3 VMs: no role label, tainted, match the affinity) | |
| 16:17 | `kubectl -n arc-runners get pods -o wide` (before) | 0 | 8 olympus-gate Running, 3 olympus-linux Running (one per onode), 1 olympus-kvm | |
| 16:17 | `kubectl describe node onode-0312ce` | 0 | `cpu 5400m (36%) 11820m (78%)`, `memory 11480Mi (48%) 22928Mi (96%)`; allocatable cpu 15, memory 24314640Ki | |
| 16:19 | `curl 127.0.0.1:2381/metrics` on 3 onodes (ssh) | 0 | wal_fsync le=0.008 4274811 / count 4295624 (onode-030c31; 99.5%); similar on 0312ce, 0314ac | |

## Decisions

- 2026-11-22: 6, not 5 or 9. Why: two per onode is symmetric under maxSkew 1; it matches the spec's final ceiling (6 pods); requests fit allocatable on the busiest onode with services kept.
- 2026-11-22: Prometheus PVC I/O errors (prometheus-server, qnap-iscsi) reported to the coordinator; out of this lane's scope. Queue-time metrics may be missing until fixed.

## Blocked-on

- none

## Next

1. Commit, push, open the PR, wait for Validate, run the verifier, add automerge.
