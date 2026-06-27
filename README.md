# olympus-gitops

GitOps manifests for the Olympus homelab, managed by ArgoCD running on the management host.

## Structure

```
clusters/
  mac-studio/          # OrbStack Kubernetes cluster on Mac Studio (M1 Max)
    external-secrets/  # ESO operator + ClusterSecretStore → 1Password Connect (wave 0)
    cert-manager/      # cert-manager + Let's Encrypt DNS-01/Cloudflare issuer (wave 1)
    traefik/           # Traefik ingress controller (wave 2)
```

## ArgoCD Applications

Applications are created by Ansible during the mac-studio bootstrap (`make mac-studio-bootstrap`).
They are NOT stored in this repo — Ansible manages them via `argocd app create --upsert`.

Each app points to its directory here, syncs automatically, and creates its namespace if missing.

## Bootstrap sequence

1. Ansible push seeds two secrets into the OrbStack cluster before ArgoCD syncs:
   - `eso-op-connect-token` in `external-secrets` ns (1Password Connect token for ESO)
   - `cloudflared-creds` in `cloudflared` ns (tunnel token, managed by Ansible directly)
2. ArgoCD syncs `external-secrets` (wave 0) → ESO operator + ClusterSecretStore ready
3. ArgoCD syncs `cert-manager` (wave 1) → ESO creates `cloudflare-api-token` Secret → ClusterIssuer ready
4. ArgoCD syncs `traefik` (wave 2) → ingress controller ready

## 1Password items required

| Item name           | Fields              | Used by           |
|---------------------|---------------------|-------------------|
| `Cloudflare API Token` | `credential`     | cert-manager DNS-01 |
