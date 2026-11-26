# Progress: nwlnexus/olympus-gitops#303 Storage textfile: warn on a k3s node without the writer

- **Issue:** `https://github.com/nwlnexus/olympus-gitops/issues/303`
- **Branch / worktree:** `feat/303-storage-textfile-missing` in `~/projects/personal/.worktrees/olympus-gitops-303`
- **Session:** `personal-olympus-gitops-303` (lane W7-A) on ai-agent-host; registry id `d3509dc3-8ee2-4a57-b3c8-2323bc2c7b0a`
- **Started:** 2026-11-26 02:55 UTC · **Turn cap:** 30

## Goal

```text
The role is live on all nine k3s nodes (count(node_storage_textfile_last_run_timestamp_seconds{job="kubernetes-service-endpoints"}) = 9); the warning and its promtool test are merged; it is inactive on the live Prometheus. Checks: pq.sh count = 9; promtool test rules storage-alerts.test.yaml SUCCESS; after Flux applies, ALERTS{alertname="StorageTextfileMissing"} empty and the rule is loaded. Progress file current until removal. Or stop after 30 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `pq.sh 'count(node_storage_textfile_last_run_timestamp_seconds{job="kubernetes-service-endpoints"})'` | `9` | PASS (`"v":"9"`) | |
| 2 | `promtool test rules storage-alerts.test.yaml` (rules extracted from the HelmRelease) | SUCCESS | PASS | |
| 3 | live: rule loaded, `ALERTS{alertname="StorageTextfileMissing"}` empty, expr returns 0 series | inactive | expr 0 series pre-merge; rule load pending Flux | |

## Plan

Blast radius: no index (YAML repo, olympus-sdk#836). Rule + inhibit regex in prometheus-helmrelease.yaml, two promtool
tests, one README row.

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 02:55 | `pq.sh 'count by (node) (kube_node_info)'` / textfile `max by (node)` | 0 | 9 nodes each, same names (onode-062caa … data-hub-vm); kube_node_info service `prometheus-kube-state-metrics` | |
| 02:55 | `pq.sh '<the new expr>'` | 0 | `"success"` `0` series | |
| 03:20 | `check_prometheus.py` (all test files) | 0 | every file `SUCCESS` | |
| 03:22 | `promtool check rules` / `test rules storage-alerts.test.yaml` | 0 | `SUCCESS: 105 rules found` / `SUCCESS` | |

## Decisions

- 2026-11-26: name `StorageTextfileMissing`, warning, `for: 1h`, the issue's expression verbatim; added to the
  PrometheusIngestionStopped inhibit regex (it fires on missing data).

## Blocked-on

- none

## Next

1. Commit, PR, verifier, automerge; after Flux: confirm the rule is loaded and inactive; close the issue.
