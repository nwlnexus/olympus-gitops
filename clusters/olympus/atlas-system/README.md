# atlas-system

Namespace for the in-cluster components of the atlas platform: the cluster agent, the cluster actuator and the read-only
Kubernetes MCP backend (`k8s-mcp`). Code and images ship from
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

- Image: `ghcr.io/nwlnexus/atlas-cluster-agent@sha256:e7f4ead7ed84d2fae7290439f5f2805aeb8fe94088099c5438dae58a652428e8`
  (tag `eb03a38`; multi-arch index, linux/amd64 + linux/arm64)
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

## k8s-mcp (read-only Kubernetes MCP backend)

A read-only MCP server for the cluster (olympus-sdk#916; proxy code in olympus-sdk
`packages/k8s-mcp-proxy`), reached from outside only through the cloudflared tunnel and its own
Cloudflare Access application, as the memory gateway is.

```text
client -> Cloudflare Access -> cloudflared -> Service k8s-mcp :80 -> proxy :8080 -> server 127.0.0.1:8081 -> API server
```

Deployment `k8s-mcp`, 2 replicas (PodDisruptionBudget `maxUnavailable: 1`), two containers per pod:

- **server**: `containers/kubernetes-mcp-server` v0.0.69 (`quay.io`, pinned by digest; unsigned upstream),
  run with `--config /etc/kubernetes-mcp-server/config.toml` from ConfigMap `k8s-mcp-server`: stateless
  Streamable HTTP on loopback only, in-cluster credentials, `read_only`, write/exec/kubelet tools disabled,
  Secrets denied. Probes exec `curl` against its loopback `/healthz`.
- **proxy**: `ghcr.io/nwlnexus/k8s-mcp-proxy` (pinned by digest, pulled with `ghcr-pull`), env from
  ConfigMap `k8s-mcp-proxy`. Verifies the Access token (401 otherwise), rate-limits per identity (in memory,
  so per replica), passes only the tools in `ALLOWED_TOOLS`, bounds log tails and request time, and logs one
  line per call with the caller's identity. Probes: `GET /healthz` on 8080.

Both containers run non-root (server uid 65532, proxy uid 10001) with a read-only root filesystem, no
privilege escalation, all capabilities dropped and seccomp `RuntimeDefault`.

### Boundary (`k8s-mcp-rbac.yaml`)

ClusterRole **`olympus-agents-view`**, bound to ServiceAccount `k8s-mcp`, is the limit of everything the
backend can read: `get`/`list`/`watch` on an explicit list of resources (workloads, pods and their logs,
services, config maps, events, nodes, storage, networking, metrics, and the Flux, Traefik, cert-manager and
External Secrets resources). Not granted: `secrets`, `pods/exec`, `pods/attach`, `pods/portforward`,
`nodes/proxy`, `serviceaccounts/token`, or any write. The server's read-only mode and the proxy's allowlist
are extra layers on top. The API server, and its audit log, see `system:serviceaccount:atlas-system:k8s-mcp`.

The same ClusterRole is bound to group **`olympus:agents-view`** (ClusterRoleBinding
`olympus-agents-view-group`): agent hosts on the tailnet use `kubectl` through the Tailscale operator's API-server
proxy, which impersonates that group for them (tailnet policy grant to the agent hosts' tag; olympus-sdk#935). The
host holds no Kubernetes credential. Set it up on a host with
`tailscale configure kubeconfig <operator hostname>` (writes to `$KUBECONFIG`, else `~/.kube/config`), then check
with `kubectl auth whoami` (group `olympus:agents-view`).

The token is mounted only into the server container (the pod sets `automountServiceAccountToken: false`
and declares the projected token volume itself); the proxy never sees it.

### Network (`k8s-mcp-networkpolicy.yaml`, `k8s-mcp-service.yaml`)

ClusterIP Service `k8s-mcp` port 80 to the proxy's 8080: the tunnel target
`http://k8s-mcp.atlas-system.svc.cluster.local:80`. No IngressRoute, external-dns record or tailnet Service.
Ingress to 8080 only from the `cloudflared` pods. Egress: CoreDNS, the Kubernetes API server, and TCP 443 to
Cloudflare's published IPv4 ranges (the Access signing keys; the same list as the memory gateway, so update
both together).

### Access audience

`ACCESS_TEAM_DOMAIN` is the same team domain as the memory gateway. `ACCESS_AUD` in `k8s-mcp-configmap.yaml`
is the AUD tag of this backend's Access application, printed by the olympus-infra Access playbook; it is not a
secret. Only tokens issued for that application carry this audience; every other request gets 401. To change
it, edit the value in this repository; Reloader restarts the pods.

### Clients

No MCP client entry on any host is configured here, intentionally: hosts get one only once the
personal/work guard covers these tools (olympus-sdk#929).

## atlas-cluster-actuator (signed cluster actions)

The write side of the cluster agent (olympus-sdk#922; same image, `AGENT_MODE=actuator`). It polls Hermes
for signed cluster commands, verifies each against the pinned command key and this cluster's identity, and
carries out one of four verbs with a fixed merge patch: `flux-reconcile`, `flux-suspend`, `flux-resume` and
`rollout-restart`. It never runs `kubectl` or a shell.

This directory holds its identity, RBAC, replay set, admission policy, egress rules, its credentials
(`actuator-externalsecret.yaml`: 1Password item `atlas-cluster-actuator`, fields `hermes-actuator-token` and
`cluster-id`) and its Deployment (`actuator-deployment.yaml`: one replica, `Recreate`, `AGENT_MODE=actuator`).
Hermes refuses every command until people hold the cluster action capabilities, so a running actuator with
nothing granted only polls.

### RBAC (`actuator-rbac.yaml`)

ServiceAccount `atlas-cluster-actuator`, separate from the read agent's. A ClusterRole with `get` and
`patch` only, on `apps` `deployments`/`statefulsets`/`daemonsets`, Flux `kustomizations` and
`helmreleases`; no `list`, `watch`, `create`, `update`, `delete` and no subresources. A Role in
`atlas-system` with `get` and `update` on the single ConfigMap `atlas-cluster-actuator-dedupe`
(`resourceNames`), no `create`.

### Replay set (`actuator-configmaps.yaml`)

ConfigMap `atlas-cluster-actuator-dedupe`, created empty by Flux with `kustomize.toolkit.fluxcd.io/ssa:
IfNotPresent`, so Flux never resets it. The actuator records each command id in it before it acts and never
acts on an id it has seen. If the ConfigMap is missing, every command fails closed.

### Admission policy (`actuator-admission.yaml`)

RBAC alone would let this identity patch any field of the five kinds. The `ValidatingAdmissionPolicy`
`atlas-cluster-actuator-fields` (binding `Deny`, `failurePolicy: Fail`) applies only to
`system:serviceaccount:atlas-system:atlas-cluster-actuator` and:

- admits only UPDATE of the main resource (no create, delete or subresource write);
- refuses any workload write in `kube-system`, `flux-system` and `atlas-system`;
- admits an update only if nothing changed except `metadata.annotations["reconcile.fluxcd.io/requestedAt"]`
  and `spec.suspend` (Flux kinds) or `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]`
  (workloads). Server-maintained fields (`managedFields`, `resourceVersion`, `generation`, `status`) are
  ignored in the comparison.

### Network (`actuator-networkpolicy.yaml`)

No ingress. Egress: CoreDNS, the Kubernetes API server, and TCP 443 to Cloudflare's published IPv4 ranges
(Hermes is a Cloudflare Worker; the same list as k8s-mcp, so update both together).

### Kill switches

Revoke the actuator token in IRIS (the actuator gets 401 and backs off), or scale its Deployment to 0 here.
The admission policy and RBAC stay in place regardless.
