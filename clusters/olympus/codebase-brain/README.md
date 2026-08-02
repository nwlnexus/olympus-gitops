# Codebase Brain (Argo)

Push to allowlisted `nwlnexus/*/main` → Argo Events Sensor → Argo Workflow running the
`ghcr.io/nwlnexus/codebase-brain` Job (source: `nix-darwin-hm` `scripts/codebase-brain/`).

The historical bootstrap checklist lives in `nix-darwin-hm`
`docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md`; treat this
file and the manifests here as the live runbook.

## What this app deploys

| Resource | Purpose |
| --- | --- |
| Namespace `codebase-brain` | Isolation |
| WorkflowTemplate `codebase-brain` | Mint App install token → skip stale SHA → Job `--phase all` |
| EventBus + EventSource `github-push` | GitHub `push` webhook (HMAC only; hook owned in GitHub UI) |
| Sensor `codebase-brain-push` | Filter main + allowlist → submit Workflow |
| PVC `codebase-brain-work` (50Gi, qnap-iscsi) | Shared `--work-root` cache (mutex-serialized) |
| IngressRoute + Certificate | `https://brain-events.nwlnexus.net/push` |

## Flux sync

Flux reconciles this app through `clusters/olympus/flux-kustomizations/codebase-brain.yaml`.
It depends on:

- `argo-workflows` and `argo-events` for Workflow/Sensor CRDs and controllers.
- `external-secrets-config` for 1Password-backed ExternalSecrets.
- `cert-manager-config` for the Let's Encrypt ClusterIssuer.
- `qnap-storage` for the `qnap-iscsi` PVC.

It intentionally does **not** depend on `external-dns` or `traefik-config`; the
webhook ingress is already live, and the app should not stall on transient
ingress/DNS readiness during unrelated upgrades.

## R2

ConfigMap `codebase-brain-env` → `BRAIN_R2_BUCKET=second-brain-docs` (graphs under prefix `graphs/`).

## Image pin

WorkflowTemplate image: `ghcr.io/nwlnexus/codebase-brain:a4d84cb`

Bump the tag in `workflowtemplate.yaml` after a successful
`nix-darwin-hm` workflow `codebase-brain-image` run (GHCR publish via Actions,
same pattern as olympus-sdk `ingress-discovery` / `openmemory`). The image tag
should be the short SHA built by that workflow; the cluster does not follow
`latest`.

## Workflow controls

- Sensor `codebase-brain-push` accepts only `refs/heads/main` pushes from owner
  `nwlnexus` and the hardcoded repo allowlist below.
- Sensor submission is rate-limited to one Workflow per minute. This soft
  coalesces bursts; correctness comes from the per-repo mutex and stale-SHA
  check.
- Workflow mutex `brain-{{owner}}-{{repo}}` serializes runs that share the PVC
  work root.
- Step `skip-if-stale` compares the pushed SHA with the current tip of `main`.
  If a newer push already landed, the old Workflow exits before running the
  expensive Job.
- `activeDeadlineSeconds: 10800` caps a Workflow at three hours.
- Main template retries once (`retryStrategy.limit: "1"`).
- The exit handler sends Slack only for non-`Succeeded` statuses and skips
  notification if `SLACK_WEBHOOK_URL` is unset.

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

## Allowlist

The live gate is the hardcoded `body.repository.name` filter in `sensor.yaml`:

- `olympus-sdk`
- `olympus-gitops`
- `olympus-infra`
- `nix-darwin-hm`
- `moneta`
- `nix-op-secrets`
- `second-brain`
- `olympus-tailnet`
- `homebrew-olympus`

`allowlist-configmap.yaml` mirrors `nix-darwin-hm`
`modules/repomix/repos.toml` `[groups.personal]` for operator visibility, but
the Sensor does not read it today. When the personal repo set changes, update
both `sensor.yaml` and `allowlist-configmap.yaml`. The EventSource stays
organization-scoped (`nwlnexus`) and does not carry per-repo filters.

## Ops

```bash
kubectl --context olympus get workflows -n codebase-brain
kubectl --context olympus logs -n codebase-brain -l workflows.argoproj.io/workflow=<name> -c main
kubectl --context olympus port-forward -n argo-workflows svc/argo-workflows-server 2746:2746
```

Brain PRs on `nwlnexus/second-brain` (`automation/brain-<repo>`) must **never** auto-merge.
