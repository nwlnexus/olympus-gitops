# Codebase Brain (Argo)

Push to allowlisted `nwlnexus/*/main` → Argo Events Sensor → Argo Workflow running the
`ghcr.io/nwlnexus/codebase-brain` Job (source: `nix-darwin-hm` `scripts/codebase-brain/`).

Checklist: `nix-darwin-hm` → `docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md`

## What this app deploys

| Resource | Purpose |
| --- | --- |
| Namespace `codebase-brain` | Isolation |
| WorkflowTemplate `codebase-brain` | Mint App install token → skip stale SHA → Job `--phase all` |
| EventBus + EventSource `github-push` | GitHub `push` webhook (HMAC) |
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

Create before Flux can sync ExternalSecrets successfully:

| Item | Fields | Consumed as |
| --- | --- | --- |
| `docs-api-key` | `credential` | `ANTHROPIC_API_KEY` |
| `codebase-brain-r2` | `endpoint`, `access-key-id`, `secret-access-key` | `AWS_*` |
| `codebase-brain-slack` | `webhook-url` | failure Slack notify |
| `codebase-docs-pipeline-gh-app` | `app-id`, `installation-id`, document `private-key.pem` | App → `GH_TOKEN` mint |
| `codebase-brain-github-webhook` | `secret`, `token` | EventSource HMAC + hook API |
| `gh-pull-secret` | `username`, `credential` | GHCR pull (existing) |

**Never** put a personal PAT in the Job `GH_TOKEN` path — Workflow mints an installation
token from the App PEM each run.

## GitHub webhook

Target: `https://brain-events.nwlnexus.net/push`  
Content type: `application/json`  
Events: `push`  
Secret: value of 1Password `codebase-brain-github-webhook` / `secret`

Prefer an **org webhook** filtered by the Sensor allowlist, or per-repo webhooks on the
personal-group repos only. Install the GitHub App on those repos + `second-brain`.

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
