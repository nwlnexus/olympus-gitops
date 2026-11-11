# otel-collector

OpenTelemetry collectors and metric exporters in the `otel` namespace.

| Release | Mode | What it does |
| --- | --- | --- |
| `opentelemetry-collector` (`helmrelease.yaml`) | Deployment | OTLP gateway for traces, metrics and logs sent by apps |
| `otel-logs` (`helmrelease-logs.yaml`) | DaemonSet, every node | Pod logs (`/var/log/pods`) with Kubernetes metadata, to Loki |
| `otel-audit` (`helmrelease-audit.yaml`) | DaemonSet, k3s servers only | Kubernetes API audit log, to Loki |
| `node-exporter`, `kube-state-metrics` | | Prometheus exporters |

## Kubernetes API audit log

kube-apiserver on each k3s server writes one `audit.k8s.io/v1` `Event` per line to
`/var/lib/rancher/k3s/server/logs/audit.log`. `otel-audit` tails that file (from the end, with read
offsets kept in `/var/lib/otel-audit` on the host) and sends each line unchanged to Loki.

- Run as root: the audit directory is root-owned with mode 0700. All capabilities are dropped, the root
  filesystem is read-only, and the pod has no ServiceAccount token and no RBAC.
- Until a server has the audit directory, its pod waits in `ContainerCreating` and starts once the
  directory exists.

Stream: `{service_name="k8s-audit"}` (labels `service_name`, `k8s_cluster_name`). Structured metadata
per line: `k8s_node_name`, `k8s_audit_verb`, `k8s_audit_level`, `k8s_audit_response_code`. Everything
else (user, groups, object, request URI, audit ID) is in the JSON body; use `| json`.

All requests by the Kubernetes MCP ServiceAccount, made directly or by impersonating it
(`impersonatedUser` is the identity RBAC evaluated):

```logql
{service_name="k8s-audit"} | json | user_username="system:serviceaccount:atlas-system:k8s-mcp" or impersonatedUser_username="system:serviceaccount:atlas-system:k8s-mcp"
```

All forbidden (403) responses:

```logql
{service_name="k8s-audit"} | k8s_audit_response_code="403" | json
```

All Secret requests:

```logql
{service_name="k8s-audit"} | json | objectRef_resource="secrets"
```

Group membership (`user.groups`, `impersonatedUser.groups`) is an array, so extract it as JSON text and match it with its quotes:

```logql
{service_name="k8s-audit"} | json groups="user.groups" | groups=~`.*"olympus:agents-view".*`
```

Alerts on these identities are in `../observability/loki-rules-k8s-audit.yaml`.
