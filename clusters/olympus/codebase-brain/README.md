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

## Event flow

1. GitHub sends an org-level `push` webhook to
   `https://brain-events.nwlnexus.net/push`.
2. Traefik routes the request to the Argo Events service
   `github-push-eventsource-svc:12000`.
3. EventSource `github-push` validates the webhook HMAC using Secret
   `codebase-brain-github-webhook`.
4. Sensor `codebase-brain-push` accepts only:
   - `body.ref == refs/heads/main`
   - `body.repository.owner.login == nwlnexus`
   - `body.repository.name` in the allowlist
5. The Sensor creates a Workflow from WorkflowTemplate `codebase-brain` with
   parameters `owner`, `repo`, and `sha`.
6. The Workflow mints a short-lived GitHub App installation token, checks that
   the pushed SHA is still the tip of `main`, then runs the pinned Job image
   with `--phase all`.

The Sensor rate-limits submissions to one Workflow per minute. Backlog
correctness is handled inside the Workflow: stale SHAs exit before the expensive
Job step, and the per-repo mutex serializes use of the shared RWO work PVC.

## R2

ConfigMap `codebase-brain-env` → `BRAIN_R2_BUCKET=second-brain-docs` (graphs under prefix `graphs/`).

## Image pin

WorkflowTemplate image: `ghcr.io/nwlnexus/codebase-brain:a4d84cb`

Bump the tag in `workflowtemplate.yaml` after a successful
`nix-darwin-hm` workflow `codebase-brain-image` run (GHCR publish via Actions,
same pattern as olympus-sdk `ingress-discovery` / `openmemory`).

When changing the image tag:

1. Verify the GHCR image digest/tag came from the expected `nix-darwin-hm`
   commit.
2. Update only `workflowtemplate.yaml`.
3. Confirm `ghcr-pull` still exists; the image is private.
4. Reconcile `codebase-brain` and inspect the next Workflow logs before assuming
   the new image is healthy.

## 1Password (Dev vault) prerequisites

| Item | Fields | Consumed as |
| --- | --- | --- |
| `docs-api-key` | `credential`, `r2-endpoint`, `r2-access-key-id`, `r2-secret-access-key`, `webhook-secret` | Anthropic, R2/`AWS_*`, GitHub webhook HMAC |
| `automation-slack-bot` | `slack_webhook` | failure Slack notify |
| `codebase-docs-pipeline-gh-app` | `app-id`, `installation-id`, **`private-key`** = `base64(PEM)` (concealed; Connect collapses newlines) | App → `GH_TOKEN` mint |
| `gh-pull-secret` | `username`, `credential` | GHCR image pull Secret |

Encode PEM for the `private-key` field (macOS):

```bash
base64 -i ./private-key.pem | tr -d '\n' | pbcopy
```

ExternalSecret uses `decodingStrategy: Base64` so the pod sees a normal PEM file.

No `codebase-brain-github-webhook` 1Password item — HMAC is read from `docs-api-key`.

**Never** put a personal PAT in the Job `GH_TOKEN` path — Workflow mints an installation
token from the App PEM each run.

### Runtime secrets

| Kubernetes Secret | Source | Used by |
| --- | --- | --- |
| `codebase-brain-secrets` | `docs-api-key`, `automation-slack-bot` | Job Anthropic/R2 env; failure-only Slack webhook |
| `codebase-brain-github-app` | `codebase-docs-pipeline-gh-app` | `mint-gh-token` step |
| `codebase-brain-github-webhook` | `docs-api-key` / `webhook-secret` | EventSource HMAC validation |
| `ghcr-pull` | `gh-pull-secret` | Private GHCR image pulls |

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

The active allowlist is currently:

```text
olympus-sdk
olympus-gitops
olympus-infra
nix-darwin-hm
moneta
nix-op-secrets
second-brain
olympus-tailnet
homebrew-olympus
```

## Ops runbook

### Reconcile and inspect

```bash
CTX=compute-hub # use your local alias, such as olympus, if different
flux --context "$CTX" reconcile kustomization codebase-brain --with-source
flux --context "$CTX" get kustomization codebase-brain -n flux-system
kubectl --context "$CTX" get pods -n codebase-brain
kubectl --context "$CTX" get workflows -n codebase-brain
kubectl --context "$CTX" get workflow <name> -n codebase-brain -o yaml
kubectl --context "$CTX" logs -n codebase-brain \
  -l workflows.argoproj.io/workflow=<name> -c main
kubectl --context "$CTX" port-forward -n argo-workflows svc/argo-workflows-server 2746:2746
```

Both `compute-hub` and `olympus` context names appear in local runbooks for the
same live cluster. Use whichever kubeconfig alias exists on the machine.

### Troubleshooting

| Symptom | Check |
| --- | --- |
| No Workflow after a GitHub push | Confirm webhook delivery in GitHub UI, EventSource pod health, and Sensor filters (`main`, owner `nwlnexus`, allowlisted repo). |
| Webhook returns authentication errors | Verify Secret `codebase-brain-github-webhook` exists and maps to `docs-api-key` / `webhook-secret`. |
| Workflow fails before the Job step | Inspect `mint-gh-token` and `skip-if-stale`; missing App fields, malformed PEM, or a stale SHA are the common causes. |
| Job image cannot pull | Check `ghcr-pull` Secret and that the tag in `workflowtemplate.yaml` exists in GHCR. |
| Job fails during graph/doc generation | Inspect the `main` container logs and the `codebase-brain-secrets` ExternalSecret status for Anthropic/R2 fields. |
| Multiple pushes appear skipped | This is expected when newer pushes reach `main`; stale-SHA detection keeps only the current tip doing expensive work. |

Failure notifications are sent only by the Workflow `exit-handler`; successful
Workflows do not post Slack alerts.

Brain PRs on `nwlnexus/second-brain` (`automation/brain-<repo>`) must **never** auto-merge.
