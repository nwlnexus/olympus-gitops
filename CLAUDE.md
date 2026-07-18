# Claude Code Instructions — olympus-gitops

> Full context in `AGENTS.md`. This file covers Claude Code-specific operations.

## Key Flux Commands

There is one gitops-managed cluster; its kube-context is `compute-hub` (there is
no `olympus` context — despite the repo path being `clusters/olympus`).

```bash
# Force-sync a specific kustomization (after pushing a change)
flux --context compute-hub reconcile source git flux-system
flux --context compute-hub reconcile kustomization <name>

# Force-sync a HelmRelease
flux --context compute-hub reconcile helmrelease <name> -n <namespace>

# Check all kustomization status
kubectl --context compute-hub get kustomization -n flux-system
kubectl --context compute-hub get helmrelease -A
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

[Stakater Reloader](https://github.com/stakater/Reloader) is deployed on compute-hub (`reloader` namespace). It watches Secrets and ConfigMaps and triggers rolling restarts of Deployments/StatefulSets/DaemonSets that are annotated to use them.

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

`watchGlobally: false` is set — Reloader only acts on annotated workloads.

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
