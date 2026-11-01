# Progress: nwlnexus/olympus-sdk#707 balance workloads across nodes and architectures

- Session: personal-olympus-sdk-707 on ai-agent-host; registry id see memory (session-registry olympus-sdk#707)
- Branches: olympus-gitops feat/707-cluster-balance (this file), olympus-sdk feat/707-multiarch-images

## Goal

```text
/goal nwlnexus/olympus-sdk#707 Done when: (1) every running non-DaemonSet container outside kube-system/flux-system has cpu+memory requests (jq count 0, exceptions listed); (2) descheduler deployed via Flux and a run evicted >=1 pod without a PDB violation, health gate PASS after; (3) no node >35% of the non-DaemonSet pods it can run, naraka-01 >3, >=5 non-CI workloads on the arm64 VMs (before/after in a comment); (4) every arm64-scheduled image verified multi-arch, no exec format error / CrashLoopBackOff on arm64 nodes for 24 h; (5) memory-gateway, memory-workers, ingress-discovery publish linux/amd64+linux/arm64. Progress file docs/progress/2026-11-01-707-cluster-balance.md is current. Or stop after 80 turns.
```

## Done-when checks

| # | Check | Expected | Status |
|---|---|---|---|
| 1 | jq: running non-DS containers without requests (excl. kube-system, flux-system) | 0 (+ listed exceptions) | todo |
| 2 | descheduler logs + PDB + k3s-health-gate.sh | >=1 eviction, gate PASS | todo |
| 3 | pods per node | max <=35%, naraka-01 >3, >=5 on arm64 | todo |
| 4 | skopeo per arm64 workload; events on arm64 nodes 24 h | arm64 in index; none | todo |
| 5 | imagetools inspect x3 | arm64 listed | todo |

Baseline (2026-11-01 ~16:40Z): onode-0312ce 20, onode-0314ac 17, onode-030c31 9, onode-0636e4 5, onode-062caa 5, naraka-01 3, Mac VMs 0 (non-DS). 75/116 containers without cpu request. Arch survey: scratchpad arch-2026-11-01.txt (41 multi+arm64, 1 amd64-only TEI, 9 unknown).

## Plan

| Step | What | Model | Status |
|---|---|---|---|
| 1 | Requests from Prometheus p95 7 d usage, all workloads without requests | opus survey, sonnet edits | done 9fdc161 (docs/sizing/2026-11-01-requests.md) |
| 2 | topologySpread (hostname, ScheduleAnyway) on multi-replica; PDBs | opus subagent | doing |
| 3 | descheduler via Flux (CronJob 30 min; exclusions; PDB-aware) | opus subagent | doing |
| 4 | arm64 opt-in: toleration + soft affinity for multi-arch workloads; amd64 pin for the rest | sonnet survey, opus review | todo |
| 5 | olympus-sdk: multi-arch builds for our 3 images | sonnet subagent | doing |

## Evidence log

| When | Command | Exit | Key output | Commit |
|---|---|---|---|---|
| 11-01 | yamllint; kustomize+kubeconform 31 dirs; promtool; helm template 22 HelmReleases | 0 | failed=0; all requests on intended containers | 9fdc161 |

## Decisions

- Taint stays on the Mac VMs; workloads opt in (toleration + preferred affinity), amd64-only ones get a hard amd64 selector.
- Requests from measured usage (p95), not guesses; no new limits.
- Exceptions to Done-when 1 (not Flux-managed): 1password/onepassword-connect (hand Helm), trident-controller (TridentOrchestrator CR), tailscale/nameserver (DNSConfig has no resources) = 9 containers.
- Kept: embedder cpu 2 (throughput reservation); redpanda broker (chart ties requests to limits). prometheus-server request capped at its 2Gi limit (peak 1994Mi): limit raise is an owner decision.
- Order: requests -> spread -> descheduler -> arm64 opt-in (descheduler needs requests to judge utilisation).

## Blocked-on

- none

## Next

Steps 1 (survey) and 5 in parallel.
