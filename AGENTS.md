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
