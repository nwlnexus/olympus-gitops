# olympus-gitops — Agent Context

This repo contains Flux CD GitOps manifests for the Olympus homelab. All cluster state is
declared here and reconciled by Flux on the single managed cluster.

## Topology

There is exactly **one** gitops-managed cluster. Flux syncs the single repo path
`./clusters/olympus` onto it (kube-context `compute-hub`).

| Name | Role |
|------|------|
| **compute-hub** | The only gitops-managed cluster. k3s, 9 nodes: five control-plane/etcd servers (`onode-030c31`, `onode-0312ce`, `onode-0314ac`, plus `onode-062caa` and `onode-0636e4`, which are tainted `olympus.io/role=agent-services`), the amd64 worker `naraka-01`, and three arm64 VM workers (`data-hub-vm`, `mmini-01-vm`, `mmini-02-vm`, tainted `olympus.io/arch=arm64`). Read the live set with `kubectl --context compute-hub get nodes` rather than trusting this line. Everything under `clusters/olympus/` reconciles here. |
| **QNAP** | Out-of-band **by design** — NOT in gitops. Provides iSCSI (Trident, StorageClass `qnap-iscsi`) to compute-hub. |
| **data-hub** | A **host only** (Mac Studio, formerly named `ai-hub`) — **not a cluster**. The fallback inference node: Ollama is retired, primary inference is the cluster LiteLLM (`clusters/olympus/inference/`) routing to llama-server on the A9 host (`100.89.177.55`), and data-hub runs a llama-server twin on `100.95.232.41:8082` that only `coder-light` falls back to (tailnet IPs — name-independent), plus a macOS CI runner; a temporary Postgres :5432 remains until WS9 of olympus-sdk#444. The old data tier (Redis, ClickHouse, Kafka) is retired. Its old OrbStack/Colima k3s was retired long ago. Manifests referencing `data-hub` point at these host services (short name resolved by CoreDNS in `tailscale-dns/`) and are correct — do not treat data-hub as a cluster. 1Password items `ai-hub-data-services` / `ai-hub-secrets` keep their legacy names; they are item titles, not hostnames. |
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

## GitNexus

This repo has no GitNexus index on purpose: it is Kubernetes YAML, Flux objects and SQL with almost no code symbols (an index-only build on 2026-11-08 found 2 functions), so impact and detect_changes have nothing to analyse (olympus-sdk#836).
