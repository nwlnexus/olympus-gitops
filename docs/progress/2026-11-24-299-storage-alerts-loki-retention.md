# Progress: nwlnexus/olympus-gitops#299 Storage incident 17–24 Nov (cluster side: alerts, Loki PVC retention, runbook)

- **Issue:** `https://github.com/nwlnexus/olympus-gitops/issues/299`
- **Branch / worktree:** `fix/299-storage-alerts-loki-retention` in `~/projects/personal/.worktrees/olympus-gitops-299`
- **Session:** `personal-olympus-gitops-299` (lane W6-A) on ai-agent-host; registry id `fe2d5b99-8966-4ab0-b4c6-bdef51612961`
- **Started:** 2026-11-24 13:00 UTC · **Turn cap:** 80
- **Draft PR:** not yet
- **Scope:** cluster side only. Host-side iSCSI timeouts, the 30 s path-loss test and the leftover LUN are lane W6-B / owner.

## Goal

```text
Cluster side of olympus-gitops#299: alerts for node fs errors/read-only remounts, Prometheus self-health (ingestion stopped, WAL/TSDB failures, head corruption) with a dead-man that stops when Prometheus stops ingesting, long CrashLoopBackOff, pod volume I/O errors; loki STS PVC retention Retain/Retain and every other STS audited; runbook "qnap-iscsi volume ext4 aborted" merged. Checks: PATH=<promtool>:$PATH python3 clusters/olympus/observability/tests/check_prometheus.py exits 0 with the new tests; grep whenScaled/whenDeleted Retain in loki-helmrelease.yaml; runbook file present; after merge: Flux Kustomization observability Ready at the merge commit, the Prometheus rules API lists the new alerts, kubectl shows loki STS Retain/Retain. Progress file docs/progress/2026-11-24-299-storage-alerts-loki-retention.md is current until removal. Or stop after 80 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `PATH=<scratch>/bin:<scratch>/venv/bin:$PATH python3 clusters/olympus/observability/tests/check_prometheus.py` | exit 0, test files incl. storage-alerts.test.yaml SUCCESS | not run | |
| 2 | `grep -n -A3 'persistence:' clusters/olympus/observability/loki-helmrelease.yaml` | whenScaled: Retain, whenDeleted: Retain | not run | |
| 3 | `test -f clusters/olympus/qnap-storage/README.md && grep -n 'ext4 aborted' clusters/olympus/qnap-storage/README.md` | runbook section present | not run | |
| 4 | post-merge `kubectl get sts -n observability loki -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'` | Retain/Retain | not run | |
| 5 | post-merge `curl -s obs-prometheus:9090/api/v1/rules` lists PrometheusIngestionStopped etc. | present, health ok | not run | |

## Plan

### Blast radius

Blast radius: no index (olympus-gitops has no GitNexus index on purpose, CLAUDE.md "GitNexus"; YAML only).

### Steps

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Live audit: exporters, metrics, Loki data, STS retention | opus | main | done |
| 2 | Prometheus rules + Watchdog + inhibits + promtool tests | opus | main | todo |
| 3 | Loki ruler rule for pod volume I/O errors | opus | main | todo |
| 4 | Loki STS retention Retain/Retain | opus | main | todo |
| 5 | Runbook in qnap-storage/README.md | opus | main | todo |
| 6 | claim-verifier, ready, automerge label, Flux/rules check, issue comment | sonnet (verifier) | subagent | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 13:05 | pq `max(timestamp(up))` at 2026-11-17T08:24Z | 0 | `1794903548.609` = 2026-11-17 08:19:08 UTC (last sample stored before the gap) | |
| 13:05 | pq `absent(up)` at 2026-11-20T00:00Z | 0 | `{"m":{},"v":"1"}` | |
| 13:05 | pq `count by (__name__)({__name__=~"node_filesystem_(readonly|device_error)|node_ext4.*|.*iscsi.*|node_textfile.*"})` | 0 | only node_filesystem_device_error, node_filesystem_readonly, node_textfile_scrape_error: no ext4 or iSCSI metric | |
| 13:10 | pq `count by (device_error, fstype)(node_filesystem_device_error{job="node-exporter"} == 1)` | 0 | `permission denied` on 212 tmpfs, 3 nfs4, 12 ext4 (kubelet pod mounts) | |
| 13:12 | `kubectl get sts -A` retention columns | 0 | only `observability loki Delete Delete`; 9 others Retain/Retain | |
| 13:20 | Loki final LogQL, 2026-11-24 04:00–12:20 | 0 | grafana, loki-0, prometheus-server, redpanda-0, portainer matched; 0 matches 10–17 Nov and after 12:30 | |
| 13:15 | baseline `check_prometheus.py` | 0 | `SUCCESS` | fc7df11 |

## Decisions

- 2026-11-24: Prometheus self-metrics cannot alert on a dead TSDB: commit of every append failed from 08:19 on 17 Nov (no stored sample 08:19 → 24 Nov 12:08), so only absent()-style rules fired. Primary signals are therefore `absent(up)` (evaluated from the in-memory head) and a Watchdog that only fires while samples are ingested, so healthchecks.io pages from outside. Why: data evidence above.
- 2026-11-24: no ext4 error or iSCSI session metric is exposed by any running exporter; node-exporter cannot statfs kubelet CSI mounts (permission denied), so node_filesystem_device_error excludes `permission denied`. Pod log I/O errors via the Loki ruler cover the workloads; kernel-log / textfile-collector signal is a follow-up issue.
- 2026-11-24: runbook lives in clusters/olympus/qnap-storage/README.md (runbooks in this repo are app README sections, e.g. arc/README.md "Runbook").

## Blocked-on

- none

## Next

1. Write the storage-health rule group, tests, inhibits; then Loki rule, Loki values, runbook.
