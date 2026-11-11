# atlas-system

Namespace for the in-cluster components of the atlas platform. Code and images ship from
**olympus-sdk**; this directory is manifests only. Further components may be added here: each
brings its own manifests and NetworkPolicy allow rules (the namespace is default-deny).

## atlas-cluster-agent

The cluster agent (olympus-sdk `packages/cluster-agent`; it replaced `ingress-discovery`,
olympus-sdk#919). One leader-elected Deployment with two publishers, both POSTing to Hermes
(a Cloudflare Worker, not in-cluster) at `https://api.nwlnexus.net/graphql`:

- **launcher**: watches Traefik `IngressRoute` objects cluster-wide and publishes the ones opted in
  with `launcher.olympus.io/*` annotations as App Launcher cards.
- **cluster state**: watches nodes, Deployments, StatefulSets, DaemonSets and Flux Kustomizations and
  HelmReleases, and publishes a summary of them (no Pods, Secrets or ConfigMaps).

- Image: `ghcr.io/nwlnexus/atlas-cluster-agent@sha256:4d92524aa569f1d19a1dca7cc44bf558bc6a2aadb7c4bc97942ea099d13f4b79`
  (tag `79fd279`; multi-arch index, linux/amd64 + linux/arm64)
- Replicas: 1 (leader-elected via Lease `atlas-cluster-agent-leader`; safe to bump to 2 for HA)
- Health: `GET /healthz` on port 8080 (liveness + readiness; not gated on leadership)
- Flux: Kustomization `atlas-system` (`../flux-kustomizations/atlas-system.yaml`), health-checked on
  the Deployment. Nothing depends on it.

### RBAC (`rbac.yaml`)

As the agent's `docs/RBAC.md` states: a ClusterRole with `get`, `list`, `watch` on `nodes`,
`apps` `deployments`/`statefulsets`/`daemonsets`, Flux `kustomizations` and `helmreleases`, and
Traefik `ingressroutes`; a Role in `atlas-system` with `get`, `create`, `update` on `leases`. No access
to Secrets, ConfigMaps or Pods, and no writes outside its own Lease.

### Network (`networkpolicy.yaml`)

Default deny for the namespace. The agent pod may reach CoreDNS, the Kubernetes API server and TCP
443 on the public internet (private ranges excluded). No ingress; kubelet probes are not subject to
NetworkPolicy on k3s.

### Token

`HERMES_PUBLISH_TOKEN` comes from Secret `atlas-cluster-agent-credentials`, synced by
`externalsecret.yaml` from 1Password (vault Dev) item **`ingress-discovery`**, field
**`hermes-publish-token`**. The item keeps its old name.

- The launcher publishes with any token that carries `publish:app-launchers`.
- Cluster state needs a **cluster-bound** token with `publish:cluster-state`, issued in IRIS for this
  cluster. With an older unbound token the agent logs one Unauthorized error per resync for cluster
  state and keeps publishing the launcher.

To replace or rotate it: issue or rotate the token in IRIS, then put the new value in the
`hermes-publish-token` field of the same item. The ExternalSecret refreshes within 1h (or force it by
annotating the ExternalSecret `force-sync=$(date +%s)`); Reloader then restarts the pod
(`reloader.stakater.com/auto` on the Deployment) and the new token is used from startup.

The pull secret `ghcr-pull` reuses the 1Password item `gh-pull-secret` (vault Dev).

### Env (set by `deployment.yaml`)

| Var | Value | Source |
|---|---|---|
| `HERMES_URL` | `https://api.nwlnexus.net/graphql` | plain env |
| `HERMES_PUBLISH_TOKEN` | (the token) | Secret `atlas-cluster-agent-credentials` |
| `LEASE_NAMESPACE` | `atlas-system` | downward API `metadata.namespace` |
| `POD_NAME` | pod name | downward API `metadata.name` |
| `HEALTH_PORT` | `8080` | plain env |
| `RUST_LOG` | `info` | plain env (read by tracing) |

Defaults left implicit: `RESYNC_INTERVAL_SECS=300`, `LEASE_NAME=atlas-cluster-agent-leader`,
`CLUSTER_STATE_ENABLED=true`.

### Opting an app into the launcher

Add annotations to its Traefik `IngressRoute`:

```yaml
launcher.olympus.io/enabled: "true"          # required opt-in
launcher.olympus.io/display-name: "Grafana"  # optional (default: humanized name)
launcher.olympus.io/group: "Observability"   # optional
launcher.olympus.io/icon: "gauge"            # optional lucide icon name
```
