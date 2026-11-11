# Progress: nwlnexus/olympus-sdk#919 CA5: cluster agent cut-over (olympus-gitops half)

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/919`
- **Branch / worktree:** `feat/919-cluster-agent-cutover` (olympus-gitops)
- **Session:** `personal-olympus-sdk-919`
- **Started:** 2026-11-10 · **Turn cap:** 70
- **Draft PR:** `https://github.com/nwlnexus/olympus-gitops/pull/261`

## Goal

```text
/goal #919 Done-when: crate checks pass without a cluster; the agent runs in the cluster in atlas-system and the ingress-discovery namespace is gone; Hermes holds live state for cluster olympus (nodes, lastSeenAt under 10 minutes old); the launcher shows the same cards as before the cut-over; D1 write volume measured over one hour and recorded on the issue. Checks: in packages/cluster-agent, cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test exits 0; kubectl --context olympus -n atlas-system get deploy shows ready and kubectl --context olympus get ns ingress-discovery returns NotFound; D1 hermes-db has cluster_objects rows of kind node for cluster olympus with observed_at under 10 minutes old; app_launchers has the same ingressroute ids as before. Progress file is current until its removal. Or stop after 70 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | in `packages/cluster-agent` (olympus-sdk): `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` | exit 0 | PASS (96 tests; claim-verifier; olympus-sdk#928 merged `79fd2795`) | |
| 2 | `kubectl -n atlas-system get deploy`; `kubectl get ns ingress-discovery` | ready; NotFound | not run | |
| 3 | Hermes database: node rows for cluster `olympus`, observed under 10 minutes ago | present | not run (needs the owner's cluster token) | |
| 4 | Hermes database: `ingressroute` launcher ids before and after | identical | before: 6 rows | |
| 5 | Database write volume over one hour, recorded on #919 | comment present | not run | |

## Plan

Blast radius: no index (manifests only).

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | olympus-sdk: rename and cluster-state publisher (PR #928) | opus + fable review | subagent | done |
| 2 | Manifests: `atlas-system` namespace, RBAC, NetworkPolicy, Deployment, secrets; remove `ingress-discovery` | opus | subagent | done (baeb5ed) |
| 3 | Review, verifier, merge | fable, opus | main + subagent | todo |
| 4 | Owner: register the cluster, issue its token, replace the token in the existing secret item | owner | — | todo |
| 5 | Verify checks 2 to 5; close | fable | main | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 2026-11-11 | image build on olympus-sdk `main` (`79fd279`) | 0 | `ghcr.io/nwlnexus/atlas-cluster-agent:79fd279@sha256:4d92524aa569f1d19a1dca7cc44bf558bc6a2aadb7c4bc97942ea099d13f4b79` (multi-arch manifest list) | |
| 2026-11-11 | olympus-sdk release check after the merge | 0 | no new release tag (the PR touched no release-watched path) | |
| 2026-11-11 | subagent: yamllint; `kustomize build` of every directory piped to kubeconform; root build diff vs origin/main | 0 | `failed=0`; root diff is only `+ Kustomization/flux-system/atlas-system`, `- Kustomization/flux-system/ingress-discovery`; `validate` green | baeb5ed |
| 2026-11-11 | `gh api /orgs/nwlnexus/packages/container/<name>` for the new, old and gateway images | 0 | all three `visibility=private`, linked to the same source repository | |
| 2026-11-11 | claim-verifier at 4f3ebc9 | - | `VERDICT: PASS` (render diff, RBAC against the code, Pod Security fields, secrets, NetworkPolicy, removal safety, CI); runtime items listed as unknown until reconcile | 4f3ebc9 |

## Decisions

- 2026-11-11: The new Deployment reuses the existing publish-token secret item. Why: the image works with either token; with the current token the launcher keeps publishing and the cluster-state publish is refused and retried, so the cut-over does not wait for the new token.
- 2026-11-11: The old `ingress-discovery` directory and its Flux Kustomization are removed in the same PR as the new ones are added. Why: both publish full launcher snapshots, so a short overlap or gap is harmless; two long-lived publishers are not wanted.
- 2026-11-11: Namespace `atlas-system` is owned by its own Flux Kustomization so later components can depend on it.
- 2026-11-11: A default-deny NetworkPolicy covers the whole namespace; the agent pod gets egress to DNS, the API server and public TCP 443 only. Why: later components in this namespace start denied.
- 2026-11-11: Not knowable before Flux reconciles: the image pull for the new package name with the existing pull secret, the pod reaching the API server and the platform API through the new policy, removal of the old namespace. If the new pod cannot start, launcher cards stay as they are (no publish means no sweep).

## Blocked-on

- none

## Next

1. claim-verifier; remove this file; PR body; ready and automerge (the session's merge of a workload-creating PR may be denied; then the owner merges).
2. After reconcile: checks 2 and 4. After the owner's token swap: checks 3 and 5.
