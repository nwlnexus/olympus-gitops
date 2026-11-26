# Progress: nwlnexus/olympus-gitops#306 qnap-iscsi orphaned LUNs and Trident volumes

- **Issue:** `https://github.com/nwlnexus/olympus-gitops/issues/306`
- **Branch / worktree:** `docs/306-retire-retain-volume` in `/home/nwilliams-lucas/projects/personal/.worktrees/olympus-gitops-306`
- **Session:** `personal-olympus-gitops-306` (lane W7-D) on ai-agent-host; registry id `f0fed2a1-b423-4c93-9b7b-d8492953fdff`
- **Started:** 2026-11-26 08:20 UTC · **Turn cap:** 40
- **Draft PR:** not yet

## Goal

```text
Each orphan identified (creation time, provisioning/claim origin); owner decides keep/delete per volume, deletion via tridentctl delete volume; runbook clusters/olympus/qnap-storage/README.md gains "retire a Retain volume"; stale record pvc-ff2f8529 handled the supported way; optional orphan check recorded as later. Checks: Prometheus kube_persistentvolume_claim_ref/created per volume -> namespace/claim/created for all 9; README has the section and no "delete its LUN on the QNAP" instruction; yamllint/validate unaffected (docs only). Progress file current until removal. Or stop after 40 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `curl -s http://obs-prometheus:9090/api/v1/query --data-urlencode 'query=max by (persistentvolume,claim_namespace,name) (last_over_time(kube_persistentvolume_claim_ref{persistentvolume=~"pvc-(8ab09441\|09f20f4f\|18289523\|b034286d\|bc3cc44a\|2a13644f\|ba7b5ff8\|d8d0ace3\|dc5f65f6).*"}[31d]))'` | 9 series with claim namespace/name | PASS (table in the issue comment) | |
| 2 | `grep -n "## Runbook: retire a Retain volume" clusters/olympus/qnap-storage/README.md; grep -c "its LUN on the QNAP" clusters/olympus/qnap-storage/README.md` | section line printed; count `0` | PASS | |
| 3 | owner: `tridentctl delete volume` per the issue comment, then `tridentctl get volume -n trident` | the deleted volumes are gone; QNAP LUN list = 8 | not run (owner) | |

## Plan

Blast radius: no index (docs-only change in olympus-gitops).

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Origin of each volume (Prometheus KSM history, Trident logs, gitops history) | opus | main | done |
| 2 | Supported retirement of the stale record (QNAP readme/issues, upstream Trident source) | opus | main | done |
| 3 | Runbook section + fix recovery step 8 | opus | main | done |
| 4 | Issue comment with per-volume recommendation + owner commands; PR; verifier; automerge | opus | main | doing |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 08:00 | KSM `kube_persistentvolume_claim_ref` / `_created` per volume (31 d) | 0 | e.g. `pvc-8ab09441… memory data-falkordb-0`, created `2026-10-21 03:02:26` | |
| 08:05 | `count(count by (persistentvolume) (kube_persistentvolume_info))` 10-29 | 0 | `10-29 18:28 16`, `10-29 18:29 10` (from 19) | |
| 08:06 | gitops PR #173 merged `2026-10-29T17:52:56Z` (retire mem0 + FalkorDB, "delete PVC memory/data-falkordb-0 and the three Released PVs" after merge); PR #124 merged `2026-10-21T02:47:36Z` (ch-ui, pgadmin removed, "data are lost") | 0 | | |
| 08:10 | `kubectl logs trident-controller… -c storage-api-server` | 0 | `2026-11-24T23:32:38 … unmap failed, Error : Unmap IscsiTarget fail, Msg : Unmap Lun : 8; IscsiTarget : 9; … Error Code : -19` | |
| 08:12 | upstream NetApp/trident v24.06.0 `core/orchestrator_core.go` deleteVolume | 0 | "If the volume does not exist on the backend, the driver will not return an error." | |

## Decisions

- 2026-11-26: stale record pvc-ff2f8529: no documented retirement in the QNAP fork (readme, issues; binary-only); leave it, retry after a plugin upgrade, ask QNAP otherwise; no CR/finalizer edit.
- 2026-11-26: optional periodic orphan check = later (in the issue, no new issue).

## Blocked-on

- Owner: keep/delete decision and `tridentctl delete volume` runs (lanes have no exec/tridentctl).

## Next

1. Commit, PR, issue comment, verifier, automerge (docs-only, not a shared golden).
