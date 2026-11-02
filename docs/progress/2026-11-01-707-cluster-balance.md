# Progress: nwlnexus/olympus-sdk#707 balance workloads across nodes and architectures

- Session: personal-olympus-sdk-707 on ai-agent-host; registry id see memory (session-registry olympus-sdk#707)
- Branches: olympus-gitops feat/707-cluster-balance (this file), olympus-sdk feat/707-multiarch-images

## Goal

```text
/goal nwlnexus/olympus-sdk#707 Done when: (1) every running non-DaemonSet container outside kube-system/flux-system has cpu+memory requests (jq count 0, exceptions listed); (2) [amended 11-01, owner] descheduler deployed via Flux, runs every 30 min without errors and evicts when a node is over target, health gate PASS; (3) no node >35% of the non-DaemonSet pods it can run, naraka-01 >3, >=5 non-CI workloads on the arm64 VMs (before/after in a comment); (4) every arm64-scheduled image verified multi-arch, no exec format error / CrashLoopBackOff on arm64 nodes for 24 h; (5) memory-gateway, memory-workers, ingress-discovery publish linux/amd64+linux/arm64. Progress file docs/progress/2026-11-01-707-cluster-balance.md is current. Or stop after 80 turns.
```

## Done-when checks

| # | Check | Expected | Status |
|---|---|---|---|
| 1 | jq: running non-DS containers without requests (excl. kube-system, flux-system) | 0 (+ listed exceptions) | PASS 11-02 18:20 (9 = the listed exceptions) |
| 2 | descheduler runs (amended: clean runs every 30 min, evicts when over target) + k3s-health-gate.sh | clean runs, gate PASS | PASS 11-01 19:07 (amended Done-when, issue comment) |
| 3 | pods per node | max <=35%, naraka-01 >3, >=5 on arm64 | PASS 11-02 18:20 (max data-hub-vm 15/61 = 25%; naraka-01 7; 21 non-CI on arm64) |
| 4 | skopeo per arm64 workload; events on arm64 nodes 24 h | arm64 in index; none | PASS 11-02 18:20 (19/19 images arm64; 0 exec format, 0 CrashLoop, 0 Warning events on the 3 VMs) |
| 5 | imagetools inspect x3 | arm64 listed | PASS 11-01 (skopeo: 3 OCI indexes amd64+arm64) |

Baseline (2026-11-01 ~16:40Z): onode-0312ce 20, onode-0314ac 17, onode-030c31 9, onode-0636e4 5, onode-062caa 5, naraka-01 3, Mac VMs 0 (non-DS). 75/116 containers without cpu request. Arch survey: scratchpad arch-2026-11-01.txt (41 multi+arm64, 1 amd64-only TEI, 9 unknown).

## Plan

| Step | What | Model | Status |
|---|---|---|---|
| 1 | Requests from Prometheus p95 7 d usage, all workloads without requests | opus survey, sonnet edits | done 9fdc161 (docs/sizing/2026-11-01-requests.md) |
| 2 | topologySpread (hostname, ScheduleAnyway) on multi-replica; PDBs | opus subagent | done 01e11c0 (spread on 5 multi-replica Deployments; cloudflared PDB) |
| 3 | descheduler via Flux (CronJob 30 min; exclusions; PDB-aware) | opus subagent | done 4364791 (docs/sizing/2026-11-01-descheduler.md) |
| 4 | arm64 opt-in: toleration for multi-arch stateless; amd64 pin for the rest; pin new index digests | opus subagent | merged #186 2a46669 |
| 5 | olympus-sdk: multi-arch builds for our 3 images | sonnet subagent | merged 6d4faef; indexes published |

## Evidence log

| When | Command | Exit | Key output | Commit |
|---|---|---|---|---|
| 11-01 | gitops #185 merged (steps 1-3) | - | verifier PASS; Flux applied d4d8d49; descheduler CronJob */30 | gitops main |
| 11-01 | pods per node after #185 (non-DS) | 0 | onode-030c31 15, onode-0314ac 12, naraka-01 12, onode-0312ce 10, onode-0636e4 5, onode-062caa 5 | - |
| 11-01 | descheduler run 17:30Z | 0 | 030c31 overutilized; 4 underutilized; evicted 0 (all pods < minPodAge 1h after the 17:17 rollout) | - |
| 11-01 | skopeo --raw sha-6d4faef / 6d4faef | 0 | memory-gateway index 161d7856 = recorded DIGEST; memory-workers b2e00a4a = DIGEST; ingress-discovery dcf85070; all linux/amd64,linux/arm64 | sdk 6d4faef |
| 11-01 | gitops #186 merged (arm64 opt-in, digest pins) | - | verifier PASS (Hermes 1.45.0 accepts iconUrl; pods IPv4-only) | 2a46669 |
| 11-01 | pods per node after #186 | 0 | data-hub-vm 14, onode-0314ac 10, onode-030c31 10, onode-0312ce 6, onode-0636e4 5, onode-062caa 5, naraka-01 5, mmini-01-vm 3, mmini-02-vm 1; 18 non-CI pods on arm64; no exec format/CrashLoop | - |
| 11-01 | loki HelmRelease Stalled (UpgradeFailed: StatefulSet spec Forbidden) | - | cause: #185 moved singleBinary.persistence under sidecar -> storageClassName dropped; fixed by gitops #187 | b9be4a1 |
| 11-01 | regression sweep #185+#186 renders (all HelmReleases + kustomize dirs) | 0 | only loki unintended; all else excluded/intended; after #187 loki HR True UpgradeSucceeded, loki-0 20m/640Mi | gitops main |
| 11-01 | gitops #188 merged (memory stack unpinned; owner decision) | - | verifier PASS; embed worker on data-hub-vm, extract worker on mmini-01-vm; gateway/litellm on amd64 non-agent nodes; postgres+embedder still pinned; backup amd64-only (VMs lack nfs-common) | gitops main |
| 11-01 | pod egress from mmini-01-vm (extract worker) | 0 | litellm readiness 200, A9 /health 200; postgres connections from 10.42.8.9 and 10.42.10.19; queue embed done 3, extract done 1 (20 min) | - |
| 11-01 | descheduler runs 18:00/18:30/19:00 | 0 | totalEvicted=0; 19:00: 7 underutilized, 0 overutilized (pods 5-15%, cpu 1-13%); topology spread "already balanced" | - |
| 11-01 | one-off --dry-run Job with tightened thresholds | denied | auto-mode [Shared Cluster Mutation]; temp file removed | - |
| 11-01 | k3s-health-gate.sh (infra main) | 0 | RESULT: PASS (22 checks); 9/9 Ready; flux 31/31 + 25/25; 107 pods no problems | - |
| 11-01 | pods per node 19:08 | 0 | data-hub-vm 15, onode-0314ac 12, onode-030c31 11, naraka-01 7, onode-0312ce 6, mmini-01-vm 4, onode-0636e4 2, onode-062caa 1, mmini-02-vm 1 (max 15/59 = 25%) | - |
| 11-01 | mini VMs 5f01 | 0 | 0 on both (owner cleanup) | - |
| 11-01 | prometheus limit 2Gi->3Gi, request 2240Mi (owner yes) | 0 | helm template: requests 40m/2240Mi, limits memory 3Gi | 0e8b3c7 |
| 11-01 | steps 2-3 validation: yamllint; kustomize+kubeconform root 53 valid; helm template descheduler 0.37.0; policy decoded by v0.37.0 binary | 0 | 0 invalid; CronJob */30; strict decode OK | 4364791 |
| 11-01 | claim-verifier olympus-sdk#708 | - | PASS: 3 image jobs build linux/arm64 (gateway pnpm under QEMU 358s; ingress-discovery cross-compile 35s); no push on PR | 8ca6280 |
| 11-01 | yamllint; kustomize+kubeconform 31 dirs; promtool; helm template 22 HelmReleases | 0 | failed=0; all requests on intended containers | 9fdc161 |
| 11-02 18:20 | pods on the 3 arm64 VMs (restartCount, waiting reason, lastState) | 0 | all Running/Succeeded, restarts 0 except Job postgres-backup-29893140 pg-dump restartCount 1 (Job Complete 1/1 at 03:00Z, lastState empty, previous logs gone; same image then ran OK in the same pod, so not exec format) | - |
| 11-02 18:20 | events: Warning on arm64 nodes/pods; any event matching exec format/CrashLoopBackOff/Back-off; pod logs --since=24h grep exec format | 0 | all empty | - |
| 11-02 18:20 | skopeo inspect --raw, 19 images on arm64 nodes (ghcr with auth) | 0 | 17 public: arm64 present; memory-gateway 67469044 and memory-workers b2e00a4a: OCI index linux/amd64,linux/arm64 | - |
| 11-02 18:20 | check 1 jq | 0 | 9: onepassword-connect x2, tailscale nameserver, trident-controller x6 (listed exceptions) | - |
| 11-02 18:20 | check 3 non-DS per node | 0 | data-hub-vm 15, onode-0314ac 12, onode-030c31 11, onode-0312ce 7, naraka-01 7, mmini-01-vm 4, onode-0636e4 2, mmini-02-vm 2, onode-062caa 1 (61 total) | - |
| 11-02 18:20 | k3s-health-gate.sh; descheduler jobs 17:00/17:30/18:00 | 0 | RESULT: PASS (22 checks); 3 Complete; 18:00 totalEvicted=0, no errors | - |

## Decisions

- Taint stays on the Mac VMs; workloads opt in (toleration + preferred affinity), amd64-only ones get a hard amd64 selector.
- Requests from measured usage (p95), not guesses; no new limits.
- Exceptions to Done-when 1 (not Flux-managed): 1password/onepassword-connect (hand Helm), trident-controller (TridentOrchestrator CR), tailscale/nameserver (DNSConfig has no resources) = 9 containers.
- Kept: embedder cpu 2 (throughput reservation); redpanda broker (chart ties requests to limits). prometheus-server request capped at its 2Gi limit (peak 1994Mi): limit raise is an owner decision.
- Descheduler thresholds pods 16/19 (cpu/mem 20/50 guard): computed per-node % after step 1 showed 20/40 would never fire. Excluded ns: kube-system, flux-system, trident, tailscale, arc-system, arc-runners, memory, system-upgrade, descheduler; iSCSI-PVC pods protected; label exclusions postgres/redpanda/prometheus/loki/tempo; max 3/node, 10/run; real mode (no soak).
- Owner 2026-11-01: memory stack may spread (drops the #567 pin); embedder (amd64 image) and postgres (iSCSI) stay pinned; postgres-backup amd64-only until nfs-common on the Mac VMs (olympus-infra follow-up).
- Done-when 2 amended by the owner (option 1) on 11-01: balanced cluster gives 0 evictions; clean 30-min runs + gate PASS suffice.
- Order: requests -> spread -> descheduler -> arm64 opt-in (descheduler needs requests to judge utilisation).

## Blocked-on

- none

## Next

All five Done-when PASS 11-02 18:20. Final verifier, remove this file, PR #184 summary, ready, merge, close #707.
