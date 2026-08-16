# olympus-gitops

GitOps manifests for the Olympus homelab. Flux CD reconciles this repository
onto the single managed cluster, `compute-hub`, from the path
`./clusters/olympus`.

## Current topology

| Name | Role |
| --- | --- |
| `compute-hub` | The only GitOps-managed Kubernetes cluster. Flux watches `clusters/olympus/` and applies every Flux `Kustomization` listed there. |
| QNAP | Out-of-band storage provider. It exposes iSCSI volumes through Trident; the live StorageClass is `qnap-iscsi`. |
| `ai-hub` | A macOS host, not a Kubernetes cluster. Manifests may reference its native services, but Flux does not manage it. |

The retired ArgoCD/OrbStack `mac-studio` layout is no longer used.

## Repository structure

```text
clusters/
└── olympus/
    ├── flux-system/              # Flux bootstrap; gotk-sync points at ./clusters/olympus
    ├── flux-kustomizations/      # One Flux Kustomization CR per app
    ├── kustomization.yaml        # Root list of Flux Kustomizations
    └── <app>/                    # App manifests rendered by Kustomize
```

Common app directories include:

- `namespace.yaml` for workload isolation.
- `helmrepository.yaml` and `helmrelease.yaml` for Helm-managed apps.
- `externalsecret*.yaml` for 1Password-sourced secrets.
- `certificate.yaml` for cert-manager DNS-01 certificates.
- `ingressroute.yaml` for Traefik v3 routes.

## Reconciliation model

1. Flux bootstraps from `clusters/olympus/flux-system`.
2. The root `clusters/olympus/kustomization.yaml` applies the Flux
   `Kustomization` objects under `clusters/olympus/flux-kustomizations/`.
3. Each Flux `Kustomization` points at one app directory and declares
   `dependsOn` for prerequisites such as External Secrets, cert-manager, Argo,
   QNAP storage, or ingress.
4. Flux prunes removed resources for app directories where `spec.prune: true`.

The baseline dependency chain is:

```text
external-secrets -> cert-manager -> cert-manager-config -> apps
                 -> external-dns
                 -> traefik-config
                 -> cloudflared
```

Individual apps can add stricter dependencies. For example,
`codebase-brain` waits for Argo Workflows, Argo Events, External Secrets,
cert-manager config, and QNAP storage.

## Secrets and certificates

All Kubernetes secrets are expected to come from 1Password through External
Secrets Operator unless a directory documents an exception. A typical secret
shape is:

```yaml
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: <kubernetes-secret-name>
  data:
    - secretKey: <target-key>
      remoteRef:
        key: <1password-item-title>
        property: <field-name>
```

TLS certificates use cert-manager DNS-01 with the `letsencrypt-prod`
ClusterIssuer. Public HTTP(S) ingress uses Traefik `IngressRoute` resources and
external-dns annotations for `nwlnexus.net`, `nwlnexus.xyz`, and `nwlnexus.io`.

## Operations

Use the live cluster context when inspecting reconciliation:

```bash
CTX=compute-hub # use your local alias, such as olympus, if different
flux --context "$CTX" get kustomizations -A
flux --context "$CTX" reconcile kustomization <name> --with-source
kubectl --context "$CTX" get kustomization -n flux-system <name>
kubectl --context "$CTX" describe kustomization -n flux-system <name>
```

For app-specific runbooks, prefer the README in the app directory. Current
specialized docs include:

- `clusters/olympus/codebase-brain/README.md`
- `clusters/olympus/ingress-discovery/README.md`
- `clusters/olympus/qnap-storage/README.md`
- `clusters/olympus/mem0/RUNBOOK-bulk-migration.md`

## Adding an app

1. Create `clusters/olympus/<app>/` with the app manifests.
2. Add `clusters/olympus/flux-kustomizations/<app>.yaml`.
3. Add that Flux `Kustomization` to `clusters/olympus/kustomization.yaml`.
4. Set `dependsOn` based on the app's real prerequisites.
5. Commit and push; Flux reconciles from Git.
