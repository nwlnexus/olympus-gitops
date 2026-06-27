# olympus-gitops — Agent Context

This repo contains Flux CD GitOps manifests for the Olympus homelab. All cluster state is
declared here and reconciled by Flux controllers running on each cluster.

## Repository Structure

```text
clusters/
├── management-hub/    # Ubuntu k3s — main ops cluster
├── compute-hub/       # Ubuntu k3s (3-node HA) — compute + storage
└── ai-hub/            # Retired OrbStack k3s (resources: [] — kept for history)
```

Each cluster directory follows this layout:

```text
clusters/<cluster>/
├── kustomization.yaml                    # Root: lists all flux-kustomizations
├── flux-kustomizations/
│   └── <app>.yaml                        # One Flux Kustomization CRD per app
└── <app>/
    ├── kustomization.yaml                # Kustomize resources list
    ├── namespace.yaml
    ├── helmrepository.yaml
    ├── helmrelease.yaml
    ├── externalsecret.yaml               # Pulls secrets from 1Password Connect
    ├── certificate.yaml                  # cert-manager LE cert (DNS-01)
    └── ingressroute.yaml                 # Traefik IngressRoute v3
```

## Clusters

| Cluster | Ingress tunnel | Domain(s) | Apps |
|---|---|---|---|
| management-hub | `ing.mgmt.nwlnexus.net` | `*.nwlnexus.net`, `*.nwlnexus.xyz` | headlamp, qnap-ui, litellm, connect-ingress, kubeconfig-merger, tailscale-operator |
| compute-hub | `ing.compute.nwlnexus.net` | `*.nwlnexus.xyz` | longhorn, democratic-csi, obsidian, whoami, tailscale-operator |

## Dependency Ordering

Flux Kustomizations use `dependsOn` to enforce ordering. The base chain for most clusters:

```
external-secrets → cert-manager → cert-manager-config → apps
                → external-dns
                → traefik-config
                → cloudflared
```

When adding a new app: check what it needs (secrets? certs? storage?) and set `dependsOn` accordingly.

## Adding a New App

1. Create `clusters/<cluster>/<app>/` with at minimum: `kustomization.yaml`, `namespace.yaml`, `helmrepository.yaml`, `helmrelease.yaml`
2. Add `clusters/<cluster>/flux-kustomizations/<app>.yaml` (Flux Kustomization CRD) with appropriate `dependsOn`
3. Add the new flux-kustomization to `clusters/<cluster>/kustomization.yaml`
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

Both active clusters run external-dns. Domain filters:
- management-hub: `nwlnexus.net`, `nwlnexus.xyz`
- compute-hub: `nwlnexus.net`, `nwlnexus.xyz`

Ownership: each cluster uses `txtOwnerId` to claim its own records. Do not duplicate the same
hostname across clusters.
