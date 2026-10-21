# olympus-gitops

Flux CD GitOps manifests for the Olympus homelab. Flux syncs `./clusters/olympus`
onto the single managed cluster (compute-hub). See [AGENTS.md](AGENTS.md) for topology,
conventions and the app layout.

## Structure

```
clusters/
  olympus/             # Desired state for compute-hub (Flux syncs this path)
    flux-system/       # Flux bootstrap
    flux-kustomizations/  # One Flux Kustomization per app
    <app>/             # Per-app manifests
```

## Hosts

- **compute-hub** — the only gitops-managed cluster (k3s).
- **data-hub** — the Mac Studio; a host only, not a cluster. The fleet's inference
  node (Ollama behind LiteLLM) and macOS CI runner, reached by the cluster over
  Tailscale. Nothing else from the old data tier is left (a temporary Postgres
  remains until WS9 of olympus-sdk#444). Formerly named `ai-hub`.

## Secrets

Secrets come from 1Password via External Secrets Operator (`ClusterSecretStore`
`onepassword-connect`). Some 1Password items keep their legacy `ai-hub-*` titles;
those are item names, not hostnames.
