# olympus-gitops — Agent Context

This repo contains Flux CD GitOps manifests for the Olympus homelab. All cluster state is
declared here and reconciled by Flux on the single managed cluster.

## Topology

There is exactly **one** gitops-managed cluster. Flux syncs the single repo path
`./clusters/olympus` onto it (kube-context `compute-hub`).

| Name | Role |
|------|------|
| **compute-hub** | The only gitops-managed cluster. Ubuntu k3s, 3-node control-plane HA + worker (`onode-03*`, `naraka-01`). Everything under `clusters/olympus/` reconciles here. |
| **QNAP** | Out-of-band **by design** — NOT in gitops. Provides iSCSI (Trident, StorageClass `qnap-iscsi`) to compute-hub. |
| **ai-hub** | A **host only** (Mac Studio) — **not a cluster**. Runs Ollama (`ai-hub.raptor-mimosa.ts.net:11434`) plus native data services (Postgres :5432 / Redis :6379 / ClickHouse :8123 / Kafka as macOS LaunchDaemons). Its old OrbStack/Colima k3s was retired long ago. Manifests referencing `ai-hub` point at these host services and are correct — do not treat ai-hub as a cluster. |
| ~~management-hub~~ | Retired (dead context). |

## Repository Structure

```text
clusters/
└── olympus/          # Desired state for the compute-hub cluster (Flux syncs this path)
```

The `clusters/olympus/` tree:

```text
clusters/olympus/
├── kustomization.yaml            # Root: lists all flux-kustomizations
├── flux-system/                  # Flux bootstrap (gotk-sync points at ./clusters/olympus)
├── flux-kustomizations/
│   └── <app>.yaml                # One Flux Kustomization CRD per app
└── <app>/
    ├── kustomization.yaml        # Kustomize resources list
    ├── namespace.yaml
    ├── helmrepository.yaml
    ├── helmrelease.yaml
    ├── externalsecret.yaml       # Pulls secrets from 1Password Connect
    ├── certificate.yaml          # cert-manager LE cert (DNS-01)
    └── ingressroute.yaml         # Traefik IngressRoute v3
```

## Ingress & Domains

Public ingress is via a remotely-managed Cloudflare named tunnel (`cloudflared`;
tunnel id in `cloudflared/configmap.yaml`, routing edited in the Cloudflare
dashboard, not here). `external-dns` (txtOwnerId `olympus`) manages records in
`nwlnexus.net`, `nwlnexus.xyz`, and `nwlnexus.io`. The live app set is whatever
is under `clusters/olympus/` — read that tree rather than a hand-maintained list.

## Dependency Ordering

Flux Kustomizations use `dependsOn` to enforce ordering. The base chain:

```
external-secrets → cert-manager → cert-manager-config → apps
                → external-dns
                → traefik-config
                → cloudflared
```

When adding a new app: check what it needs (secrets? certs? storage?) and set `dependsOn` accordingly.

## Adding a New App

1. Create `clusters/olympus/<app>/` with at minimum: `kustomization.yaml`, `namespace.yaml`, `helmrepository.yaml`, `helmrelease.yaml`
2. Add `clusters/olympus/flux-kustomizations/<app>.yaml` (Flux Kustomization CRD) with appropriate `dependsOn`
3. Add the new flux-kustomization to `clusters/olympus/kustomization.yaml`
4. Commit and push — Flux reconciles automatically (or use `flux reconcile` to trigger immediately)

## Secrets Pattern

All secrets come from 1Password via External Secrets Operator:

```yaml
# ExternalSecret pulls from 1Password Connect
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: <secret-name>
    template:           # rename fields if needed
      data:
        targetKey: "{{ .sourceKey }}"
  data:
    - secretKey: sourceKey
      remoteRef:
        key: <1password-item-title>
        property: <field-name>
```

## Certificate Pattern

All TLS certs use cert-manager DNS-01 via Cloudflare:

```yaml
spec:
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - hostname.nwlnexus.net
```

## IngressRoute Pattern (Traefik v3)

```yaml
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`hostname.nwlnexus.net`)
      kind: Rule
      services:
        - name: <service>
          port: <port>
  tls:
    secretName: <cert-secret>
```

HTTP → HTTPS redirect is handled globally at the Traefik level (no per-route redirect needed).

## External-DNS

compute-hub runs external-dns with `txtOwnerId: olympus`. Domain filters:
`nwlnexus.net`, `nwlnexus.xyz`, `nwlnexus.io`. Each managed record carries an
olympus-owned TXT registry entry so external-dns only touches records it owns.

## Codebase Brain

App path: `clusters/olympus/codebase-brain/` (depends on `argo-workflows`, `argo-events`).

- Webhook: `https://brain-events.nwlnexus.net/push`
- Job image: `ghcr.io/nwlnexus/codebase-brain:<sha>` (pinned in `workflowtemplate.yaml`)
- Secrets: 1Password Dev → ExternalSecrets (see `codebase-brain/README.md`); Job `GH_TOKEN`
  is minted per Workflow from GitHub App item `codebase-docs-pipeline-gh-app`
- Allowlist: personal `nwlnexus` repos only (mirrors nix-darwin-hm `repos.toml` `[groups.personal]`)
- Brain PRs on `second-brain` must never auto-merge

kubectl context for this cluster is `olympus` (AGENTS topology name: compute-hub).

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **olympus-gitops**. Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/olympus-gitops/context` | Codebase overview, check index freshness |
| `gitnexus://repo/olympus-gitops/clusters` | All functional areas |
| `gitnexus://repo/olympus-gitops/processes` | All execution flows |
| `gitnexus://repo/olympus-gitops/process/{name}` | Step-by-step execution trace |

<!-- gitnexus:end -->
