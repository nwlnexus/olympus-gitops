# Codebase Brain (Argo)

Push to allowlisted `nwlnexus/*/main` → Argo Events Sensor → Argo Workflow running the
`ghcr.io/nwlnexus/codebase-brain` Job (source: `nix-darwin-hm` `scripts/codebase-brain/`).

Checklist: `nix-darwin-hm` → `docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md`

## What this app deploys

| Resource | Purpose |
| --- | --- |
| Namespace `codebase-brain` | Isolation |
| WorkflowTemplate `codebase-brain` | Mint App install token → skip stale SHA → Job `--phase all` |
| EventBus + EventSource `github-push` | GitHub `push` webhook (HMAC only; hook owned in GitHub UI) |
| Sensor `codebase-brain-push` | Filter main + allowlist → submit Workflow |
| PVC `codebase-brain-work` (50Gi, qnap-iscsi) | Shared `--work-root` cache (mutex-serialized) |
| IngressRoute + Certificate | `https://brain-events.nwlnexus.net/push` |

## Image pin

WorkflowTemplate image: `ghcr.io/nwlnexus/codebase-brain:516d664`

Bump the tag in `workflowtemplate.yaml` after building/pushing a new Job image from
`nix-darwin-hm` repo root:

```bash
docker build -f scripts/codebase-brain/Containerfile \
  -t ghcr.io/nwlnexus/codebase-brain:<git-sha> .
docker push ghcr.io/nwlnexus/codebase-brain:<git-sha>
```

## 1Password (Dev vault) prerequisites

| Item | Fields | Consumed as |
| --- | --- | --- |
| `docs-api-key` | `credential`, `r2-endpoint`, `r2-access-key-id`, `r2-secret-access-key`, `webhook-secret` | Anthropic, R2/`AWS_*`, GitHub webhook HMAC |
| `automation-slack-bot` | `slack_webhook` | failure Slack notify |
| `codebase-docs-pipeline-gh-app` | `app-id`, `installation-id`, **`private-key`** (concealed field with PEM text — Connect cannot read file attachments) | App → `GH_TOKEN` mint |
| `gh-pull-secret` | `username`, `credential` | GHCR pull (existing) |

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

`allowlist-configmap.yaml` mirrors `modules/repomix/repos.toml` `[groups.personal]`
(no work/`dtlr` repos). Keep Sensor + EventSource repo lists in sync when regenerating.

## Ops

```bash
kubectl --context olympus get workflows -n codebase-brain
kubectl --context olympus logs -n codebase-brain -l workflows.argoproj.io/workflow=<name> -c main
kubectl --context olympus port-forward -n argo-workflows svc/argo-workflows-server 2746:2746
```

Brain PRs on `nwlnexus/second-brain` (`automation/brain-<repo>`) must **never** auto-merge.
