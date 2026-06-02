# Claude Code Instructions — olympus-gitops

> Full context in `AGENTS.md`. This file covers Claude Code-specific operations.

## Key Flux Commands

```bash
# Force-sync a specific kustomization (after pushing a change)
flux --context management-hub reconcile source git flux-system
flux --context management-hub reconcile kustomization <name>

# Force-sync a HelmRelease
flux --context management-hub reconcile helmrelease <name> -n <namespace>

# Check all kustomization status
kubectl --context management-hub get kustomization -n flux-system
kubectl --context management-hub get helmrelease -A

# compute-hub — use extracted kubeconfig (no direct context in local kubeconfig)
kubectl --context management-hub get secret -n headlamp headlamp-combined-kubeconfig \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/compute-hub.yaml
flux --kubeconfig /tmp/compute-hub.yaml --context compute-hub reconcile source git flux-system
```

## Dependency Chain Reference

```
external-secrets
  → cert-manager
    → cert-manager-config
  → external-dns
  → traefik-config
  → cloudflared
  → <apps> (dependsOn varies per app)
```

## Reloader — Auto-restart on Secret/ConfigMap Changes

[Stakater Reloader](https://github.com/stakater/Reloader) is deployed on all three clusters (`reloader` namespace). It watches Secrets and ConfigMaps and triggers rolling restarts of Deployments/StatefulSets/DaemonSets that are annotated to use them.

**Why this matters for ESO**: ExternalSecrets sync changes from 1Password automatically, but Kubernetes does not restart pods when a Secret value changes. Reloader bridges that gap.

### Annotation pattern

Add to any Deployment/StatefulSet/DaemonSet that mounts a Secret or ConfigMap:

```yaml
metadata:
  annotations:
    # Restart when ANY watched secret or configmap changes (recommended default)
    reloader.stakater.com/auto: "true"

    # Or scope to specific resources:
    secret.reloader.stakater.com/reload: "my-secret,other-secret"
    configmap.reloader.stakater.com/reload: "my-configmap"
```

`watchGlobally: false` is set in all clusters — Reloader only acts on annotated workloads.

### Checklist for existing deployments

When reviewing or updating any workload that uses a Secret (including ESO-managed ones), add `reloader.stakater.com/auto: "true"` to the Deployment/StatefulSet metadata if not already present.

## Common Patterns

- **New app checklist**: namespace → helmrepository → helmrelease → (externalsecret if secrets needed) → (certificate + ingressroute if public) → **add reloader annotation to Deployment**
- **Secret keys**: ExternalSecret `target.template` renames 1Password field names to what the chart expects
- **valuesFrom**: Use `HelmRelease.spec.valuesFrom` to inject secret values as Helm values
- **HTTP redirect**: Handled globally by Traefik HelmChartConfig — no per-route redirect needed

## Rules

- Do NOT hard-code IPs in manifests — use DNS names or ExternalName services
- Do NOT use `latest` image tags in HelmReleases — pin chart versions
- Always set `dependsOn` in Flux Kustomizations — ordering failures cause cascading reconciliation errors
- Commit plans to `../olympus-sdk/docs/plans/` before starting multi-step changes
