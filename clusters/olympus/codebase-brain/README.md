# Codebase Brain (Argo)

Pushes to allowlisted `nwlnexus/*/main` enter through Argo Events and submit an
Argo Workflow that runs the `ghcr.io/nwlnexus/codebase-brain` Job. The Job source
lives in `nix-darwin-hm` under `scripts/codebase-brain/`; this directory is the
cluster runbook and source of truth for the live manifests.

Historical implementation checklist:
`nix-darwin-hm/docs/superpowers/plans/2026-07-17-codebase-brain-argo-checklist.md`.
Prefer this README for current operations; the checklist predates later fixes to
namespace ownership, PEM handling, RBAC, dependencies, and the R2 bucket name.

## What this app deploys

- Namespace `codebase-brain` for app isolation; also created early by
  `argo-workflows`.
- WorkflowTemplate `codebase-brain`: mint App token, skip stale SHA, then run
  the Job with `--phase all`.
- EventBus and EventSource `github-push` for HMAC-validated GitHub `push`
  webhooks.
- Sensor `codebase-brain-push` to filter `main` and the allowlist, then submit a
  Workflow.
- PVC `codebase-brain-work`: 50Gi `qnap-iscsi` shared work-root cache.
- IngressRoute and Certificate for `https://brain-events.nwlnexus.net/push`.
- ExternalSecrets for runtime, webhook, GitHub App, and GHCR pull credentials.

## Flux bootstrap chain

`codebase-brain` is not a standalone app; it depends on Argo and shared platform
controllers:

```text
argo-workflows -> argo-events -> codebase-brain
external-secrets-config ------^
cert-manager-config ----------^
qnap-storage -----------------^
```

Important ordering details:

- `argo-workflows` creates the `codebase-brain` namespace early via
  `argo-workflows/codebase-brain-namespace.yaml`. The app Kustomization still
  includes `codebase-brain/namespace.yaml`, but the early namespace lets the
  Argo Workflows Helm chart create controller RoleBindings for
  `controller.workflowNamespaces: [codebase-brain]`.
- `flux-kustomizations/argo-workflows.yaml` sets `wait: false` because the
  HelmRelease can briefly report failed while CRDs settle. Downstream
  Kustomizations still depend on it.
- `codebase-brain` intentionally does **not** depend on `traefik-config` or
  `external-dns`. Ingress and DNS are already live, and transient readiness
  flaps there should not block Workflow/EventSource changes.

## Workflow pipeline

1. GitHub org webhook posts `push` events to `/push`.
2. EventSource validates the HMAC secret and emits the event. It does not create
   or manage GitHub hooks.
3. Sensor filters to `refs/heads/main`, owner `nwlnexus`, and the allowlisted
   repo names in `sensor.yaml`.
4. Sensor rate-limits Workflow submissions to one per minute. The Workflow also
   uses a per-repo mutex (`brain-<owner>-<repo>`) because the PVC is
   `ReadWriteOnce`.
5. `mint-gh-token` builds a GitHub App JWT from the mounted App PEM and exchanges
   it for a short-lived installation token.
6. `skip-if-stale` compares the webhook SHA to the current `main` tip. If a
   newer push already landed, it writes `false` and the Job step is skipped.
7. `run` executes `bun run src/index.ts --phase all` with the minted `GH_TOKEN`,
   shared work root, and `BRAIN_R2_BUCKET` from `codebase-brain-env`.
8. `onExit` sends a Slack notification only for non-`Succeeded` workflows.

## R2

ConfigMap `codebase-brain-env` sets:

```text
BRAIN_R2_BUCKET=second-brain-docs
```

Graphs are written under the Job's configured prefixes. Do not use the older
`nwl-codebase-brain` bucket name.

## Image pin

WorkflowTemplate image:

```text
ghcr.io/nwlnexus/codebase-brain:a4d84cb
```

Bump the tag in `workflowtemplate.yaml` after a successful `nix-darwin-hm`
`codebase-brain-image` GitHub Actions run. The workflow publishes SHA tags to
GHCR; olympus-gitops pins the exact image tag rather than `latest`.

## 1Password (Dev vault) prerequisites

- `docs-api-key`
  - Fields: `credential`, `r2-endpoint`, `r2-access-key-id`,
    `r2-secret-access-key`, `webhook-secret`
  - Consumed as: Anthropic, R2/`AWS_*`, GitHub webhook HMAC
- `automation-slack-bot`
  - Fields: `slack_webhook`
  - Consumed as: failure Slack notify
- `codebase-docs-pipeline-gh-app`
  - Fields: `app-id`, `installation-id`, `private-key` = `base64(PEM)`
  - Consumed as: GitHub App token mint
- `gh-pull-secret`
  - Fields: `username`, `credential`
  - Consumed as: GHCR image pull

Encode the GitHub App PEM for the concealed `private-key` field (macOS):

```bash
base64 -i ./private-key.pem | tr -d '\n' | pbcopy
```

ExternalSecret uses `decodingStrategy: Base64`, so the pod sees a normal PEM file
at `/github-app/private-key.pem`. The workflow also runs `normalize_pem()` before
signing so a single-line PEM paste can still be repaired.

No `codebase-brain-github-webhook` 1Password item exists; the HMAC secret is read
from `docs-api-key` / `webhook-secret`.

**Never** put a personal PAT in the Job `GH_TOKEN` path. Each Workflow mints a
short-lived installation token from the GitHub App credentials.

## GitHub webhook

Create once in the **org** UI, not via Argo:

- Target: `https://brain-events.nwlnexus.net/push`
- Content type: `application/json`
- Events: **Just the push event**
- Secret: 1Password `docs-api-key` / `webhook-secret`

Sensor filters to `refs/heads/main` plus the personal repo allowlist. Install
the GitHub App on those repos and on `second-brain`.

## Allowlist

`allowlist-configmap.yaml` mirrors `modules/repomix/repos.toml`
`[groups.personal]` (no work/`dtlr` repos). Keep the ConfigMap and Sensor
repository filters in sync when regenerating.

## Ops

```bash
kubectl --context olympus get workflows -n codebase-brain
kubectl --context olympus get eventsource,sensor,eventbus -n codebase-brain
kubectl --context olympus logs -n codebase-brain \
  -l workflows.argoproj.io/workflow=<name> -c main
kubectl --context olympus port-forward \
  -n argo-workflows svc/argo-workflows-server 2746:2746
```

Brain PRs on `nwlnexus/second-brain` (`automation/brain-<repo>`) must **never**
auto-merge.

## Troubleshooting

- **Workflow wait container exits 64:** the Workflow service account is missing
  `workflowtaskresults` RBAC. Keep those verbs in `rbac.yaml`.
- **GitHub App token mint fails:** the PEM field is not base64-encoded, or the
  App IDs are wrong. Re-encode `private-key` and verify `app-id` /
  `installation-id`.
- **Job writes to the wrong R2 bucket:** check `codebase-brain-env`; the bucket
  must be `second-brain-docs`, not the older checklist value.
- **Flux app waits on ingress/DNS:** check the dependency graph. `codebase-brain`
  should depend on Argo, ESO config, cert-manager config, and qnap-storage only.
- **Many pushes create backlog:** expected soft coalescing. Sensor rate limit and
  Workflow stale-SHA skip collapse older pushes.
- **No Slack on success:** expected. `onExit` sends Slack only for
  non-`Succeeded` status.
