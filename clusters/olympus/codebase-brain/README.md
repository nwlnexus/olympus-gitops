# Codebase Brain (Argo)

Push to allowlisted `nwlnexus/*/main` → Argo Events Sensor → Argo Workflow running the
`ghcr.io/nwlnexus/codebase-brain` Job (source: `nix-darwin-hm` `scripts/codebase-brain/`).

Checklist: `nix-darwin-hm` → `docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md`

Flux chain: `argo-workflows` → `argo-events` → `codebase-brain`. The
`codebase-brain` Kustomization also waits for `external-secrets-config`,
`cert-manager-config`, and `qnap-storage`.

## What this app deploys

| Resource | Purpose |
| --- | --- |
| Namespace `codebase-brain` | Isolation |
| WorkflowTemplate `codebase-brain` | Mint App install token → skip stale SHA → Job `--phase all` |
| EventBus + EventSource `github-push` | GitHub `push` webhook (HMAC only; hook owned in GitHub UI) |
| Sensor `codebase-brain-push` | Filter main + allowlist → submit Workflow |
| PVC `codebase-brain-work` (50Gi, qnap-iscsi) | Shared `--work-root` cache (mutex-serialized) |
| IngressRoute + Certificate | `https://brain-events.nwlnexus.net/push` |

## R2

ConfigMap `codebase-brain-env` → `BRAIN_R2_BUCKET=second-brain-docs` (graphs under prefix `graphs/`).

## Image pin

WorkflowTemplate image: `ghcr.io/nwlnexus/codebase-brain:a4d84cb`

Bump the tag in `workflowtemplate.yaml` after a successful
`nix-darwin-hm` workflow `codebase-brain-image` run (GHCR publish via Actions,
same pattern as olympus-sdk `ingress-discovery` / `openmemory`).

## 1Password (Dev vault) prerequisites

| Item | Fields | Consumed as |
| --- | --- | --- |
| `docs-api-key` | `credential`, `r2-endpoint`, `r2-access-key-id`, `r2-secret-access-key`, `webhook-secret` | Anthropic, R2/`AWS_*`, GitHub webhook HMAC |
| `automation-slack-bot` | `slack_webhook` | failure Slack notify |
| `codebase-docs-pipeline-gh-app` | `app-id`, `installation-id`, **`private-key`** = `base64(PEM)` (concealed; Connect collapses newlines) | App → `GH_TOKEN` mint |
| `gh-pull-secret` | `username`, `credential` | GHCR pull (existing) |

Encode PEM for the `private-key` field (macOS):

```bash
base64 -i ./private-key.pem | tr -d '\n' | pbcopy
```

ExternalSecret uses `decodingStrategy: Base64` so the pod sees a normal PEM file.

No `codebase-brain-github-webhook` 1Password item — HMAC is read from `docs-api-key`.

**Never** put a personal PAT in the Job `GH_TOKEN` path — Workflow mints an installation
token from the App PEM each run.

## GitHub webhook

Create once in the **org** UI (not via Argo):

- Target: `https://brain-events.nwlnexus.net/push`
- Content type: `application/json`
- Events: **Just the push event**
- Secret: 1Password `docs-api-key` / `webhook-secret`

Sensor filters to `refs/heads/main` + personal allowlist. Install the GitHub App on those
repos + `second-brain`.

The Sensor soft-coalesces events with `rateLimit: 1/min`. Backlog correctness is
handled inside the Workflow: the `skip-if-stale` step exits early when the
payload SHA is no longer the tip of `main`.

## Allowlist

`sensor.yaml` is the runtime allowlist enforcement point (`body.repository.name`
filters). `allowlist-configmap.yaml` mirrors `modules/repomix/repos.toml`
`[groups.personal]` for the Job/reference path; it does **not** drive the Sensor.
Keep both in sync when repos change.

## Failure notification

The Workflow `onExit` handler posts non-success statuses through the
`automation-slack-bot` webhook from `codebase-brain-secrets`. Successful runs do
not notify.

## Ops

```bash
kubectl --context olympus get workflows -n codebase-brain
kubectl --context olympus logs -n codebase-brain -l workflows.argoproj.io/workflow=<name> -c main
kubectl --context olympus port-forward -n argo-workflows svc/argo-workflows-server 2746:2746
```

Brain PRs on `nwlnexus/second-brain` (`automation/brain-<repo>`) must **never** auto-merge.
