# olympus-gitops

Flux CD manifests for the Olympus homelab. There is one managed Kubernetes
cluster: the `compute-hub` k3s cluster, reconciled from `./clusters/olympus`.

## Structure

```text
clusters/
└── olympus/
    ├── flux-system/            # Flux bootstrap; gotk-sync points here
    ├── flux-kustomizations/    # One Flux Kustomization CRD per app
    ├── external-secrets/       # External Secrets Operator
    ├── cert-manager/           # cert-manager and issuers
    ├── traefik/                # Ingress controller and routes
    ├── cloudflared/            # Cluster Cloudflare tunnel
    └── <app>/                  # App namespace, HelmRelease, secrets, ingress
```

`AGENTS.md` is the operator reference for topology, dependency ordering, and
manifest conventions.

## Reconciliation model

- Flux syncs this repository path: `./clusters/olympus`.
- Add an app by creating `clusters/olympus/<app>/`, adding
  `clusters/olympus/flux-kustomizations/<app>.yaml`, and listing that
  Kustomization from `clusters/olympus/kustomization.yaml`.
- Dependency order is expressed with Flux `dependsOn`; do not rely on directory
  order.
- Commit and push changes to the default branch; Flux reconciles them
  automatically.

Base ordering:

```text
external-secrets -> cert-manager -> cert-manager-config -> apps
                 -> external-dns
                 -> traefik-config
                 -> cloudflared
```

Codebase Brain extends this with:

```text
argo-workflows -> argo-events -> codebase-brain
```

## Secrets and ingress

- Secrets come from 1Password via External Secrets Operator and
  `ClusterSecretStore/onepassword-connect`.
- Public ingress uses Traefik `IngressRoute` resources with cert-manager
  DNS-01 certificates.
- DNS records are managed by external-dns for Olympus-owned hostnames.
- The Cloudflare tunnel route itself is managed outside this repository; manifests
  reference the in-cluster tunnel deployment and services.

## Codebase Brain

`clusters/olympus/codebase-brain/` deploys the Argo Events webhook and Argo
Workflow that regenerates codebase documentation for allowlisted `nwlnexus`
repositories.

- Webhook: `https://brain-events.nwlnexus.net/push`
- Runtime docs: `clusters/olympus/codebase-brain/README.md`
- Argo platform: `clusters/olympus/argo-workflows/` and
  `clusters/olympus/argo-events/`

Brain PRs on `nwlnexus/second-brain` must never auto-merge.
