# Progress: nwlnexus/olympus-sdk#724 memory: postgres-backup first attempt always gets Connection refused (retry succeeds)

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/724` (fix lives in nwlnexus/olympus-gitops)
- **Branch / worktree:** `fix/724-backup-wait-for-postgres` in `/home/nwilliams-lucas/projects/personal/.worktrees/gitops-724`
- **Session:** `personal-olympus-sdk-724` on `ai-agent-host`; registry id `ff1358ce-24b2-4b94-b72c-57e43e406b08`
- **Started:** 2026-11-03 23:30 UTC · **Turn cap:** 40
- **Draft PR:** https://github.com/nwlnexus/olympus-gitops/pull/194

## Goal

```text
/goal The cause is found, and recorded on olympus-sdk#724; three nightly postgres-backup runs in a row have restartCount 0. Checks: gh issue view 724 -R nwlnexus/olympus-sdk --comments shows a "Cause" comment naming kube-router netpol REJECT; ssh ansible@100.97.218.87 'sudo -n k3s kubectl -n memory get pods -l app.kubernetes.io/name=postgres-backup' lists 3 Completed pods started after the fix deployed, each RESTARTS 0. Progress file docs/progress/2026-11-03-724-backup-wait-for-postgres.md is current. Or stop after 40 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `gh issue view 724 -R nwlnexus/olympus-sdk --comments` | a comment headed "Cause" names the kube-router netpol REJECT race | not run | |
| 2 | `ssh ansible@100.97.218.87 'sudo -n k3s kubectl -n memory get pods -l app.kubernetes.io/name=postgres-backup'` | 3 Completed pods from runs after the fix deployed, RESTARTS 0 each | not run (first run 2026-11-04 03:00Z) | |

## Plan

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Find the cause on the cluster (netpol, iptables on postgres node, pod timings) | opus | main | done |
| 2 | Add bounded `pg_isready` wait before `pg_dump`; stub-test the loop | opus | main | done |
| 3 | Record cause on #724; draft PR; CI green; merge (progress file removed first) | opus | main | doing |
| 4 | Confirm Flux applied the new CronJob spec | opus | main | todo |
| 5 | Check 3 nightly runs (2026-11-04/05/06 03:00Z) for RESTARTS 0 and the "reachable after" log line; close #724 | haiku | scheduled check-in | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 23:22 | `k3s kubectl -n memory get pods -o wide` | 0 | `postgres-backup-29894580-bg5x4 0/1 Completed 1 ... mmini-02-vm` (all 3 runs RESTARTS 1; nodes onode-0636e4, data-hub-vm, mmini-02-vm) | |
| 23:23 | `k3s kubectl -n memory get networkpolicy` | 0 | `default-deny-ingress` + `allow-store-ingress` (postgres admits `podSelector: {}` on 5432) | |
| 23:25 | pod jsonpath startTime / retry startedAt | 0 | `podStart=2026-11-03T03:00:00Z ... run2=2026-11-03T03:00:12Z` (other runs: +1 s, +11 s) | |
| 23:27 | `iptables-save` on onode-0636e4 (postgres node), KUBE-NWPLCY/KUBE-POD-FW targets | 0 | `3 -j REJECT --reject-with icmp-port-unreachable` | |
| 23:31 | `sh -n` on the CronJob script + stub `pg_isready` (ready on 3rd / never / 1st) | 0 | `postgres reachable after 2 retries` / `postgres not reachable after 120s` exit=1 / silent | |

| 23:36 | `gh issue comment 724 -F cause.md` | 0 | `https://github.com/nwlnexus/olympus-sdk/issues/724#issuecomment-6618029544` | ad58c0c |
| 23:39 | `gh pr checks 194` | 0 | `validate	pass	38s` | ad58c0c |
## Decisions

- 2026-11-03: Fix in the Job (wait for the path with `pg_isready`, 60 x 2 s), not by loosening the netpol or sleeping a fixed time. Why: the race is in k3s's embedded kube-router controller (new pod IP enters the allow ipset only on its next sync); a bounded readiness wait covers any sync delay and still fails the Job if postgres is really down.
- 2026-11-03: Progress file lives on the olympus-gitops branch, where the change is; the issue is in olympus-sdk.

## Blocked-on

- Done-when 2 needs three nightly runs: 2026-11-04, 11-05, 11-06 at 03:00Z.

## Next

1. Verifier on the merge claim, remove this file, `gh pr ready 194`, merge, confirm Flux applied the CronJob.
2. After 2026-11-04/05/06 03:00Z runs: check RESTARTS 0 and close #724.
