# memory-gateway — deployment (olympus-sdk#450 task G10, epic #444)

The TypeScript gateway (MCP + REST) in front of the Postgres store in `..`. Design:
[`2026-10-21-memory-gateway-contract-design.md`](https://github.com/nwlnexus/olympus-sdk/blob/main/docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md)
sections 5.6, 6.1 and 9. Image: `ghcr.io/nwlnexus/memory-gateway`, built by
`.github/workflows/memory-gateway.yml` in olympus-sdk.

| File | What |
|---|---|
| `gateway.yaml` | `ConfigMap/memory-gateway-config`, `Service/memory-gateway` (80 -> 8080), `PodDisruptionBudget`, `Deployment/memory-gateway` (2 replicas) |
| `tailscale-service.yaml` | `Service/memory-ts`, LoadBalancer class `tailscale`, tailnet host `memory` (port 80 -> 8080). No Funnel, no cloudflared |
| `externalsecret.yaml` | `Secret/memory-gateway`: `DATABASE_URL` (role `memory_gateway`), mounted as a file |
| `ghcr-pull-externalsecret.yaml` | `Secret/ghcr-pull` (image pull; the package is private) |
| `networkpolicy.yaml` | `allow-gateway-ingress`: 8080 from the Tailscale proxy pod and the blackbox exporter, 9090 from Prometheus |

The stores' own policy (`../networkpolicy.yaml`) already admits every pod in the namespace, so
Postgres needed no change for the gateway pods.

## Why a separate Flux Kustomization

`../kustomization.yaml` (the `memory` Flux Kustomization, which health-checks the two StatefulSets) does
**not** include this directory. It is deployed by `../../flux-kustomizations/memory-gateway.yaml`
(path `./clusters/olympus/memory/gateway`, `dependsOn: memory`), and that file is **not** listed in
`../../kustomization.yaml`. Until it is, Flux does not apply any of the objects above, so merging cannot
affect the stores, and an unpullable image or a missing 1Password item can only ever make the
`memory-gateway` Kustomization (not `memory`) unhealthy.

## Enabling (two edits, one PR, in this order)

1. **Replace the placeholder digest** in `gateway.yaml` (`image: ghcr.io/nwlnexus/memory-gateway@sha256:000...0`)
   with the first digest the workflow publishes: the olympus-sdk `memory-gateway` run on `main` (after the
   workflow PR merges, or a manual `workflow_dispatch`) prints it in the job summary, "Record image digest".
2. **Register the Flux Kustomization**: add `  - flux-kustomizations/memory-gateway.yaml` to the end of
   `clusters/olympus/kustomization.yaml`.

Before step 2 the 1Password items must exist (otherwise the ExternalSecrets fail and the pods wait in
`ContainerCreating`; nothing else is hurt):

- `memory-stores` fields `gateway-db-password` (exists; the migrate Job already set the role's password from it);
- `gh-pull-secret` fields `username` and `credential` (exists; also used by ingress-discovery), unless the
  GHCR package is made public, in which case drop `ghcr-pull-externalsecret.yaml` and the `imagePullSecrets` entry.

To disable again: remove the line from `../../kustomization.yaml` (`prune: true` then deletes the objects).

## Owner-supplied values (placeholders)

| Value | Where | Status |
|---|---|---|
| Image digest | `gateway.yaml` (`image:`) | placeholder (64 zeros), see above |
| `MEMORY_ACCESS_TEAM_DOMAIN` (`https://<team>.cloudflareaccess.com`) and `MEMORY_ACCESS_AUD` | commented out in the ConfigMap in `gateway.yaml` | issue olympus-sdk#451 creates the Access application. Uncomment **both** (or neither) when it does |

With the two Access values unset the gateway starts, the Access-JWT path is disabled (a request carrying only
an Access JWT is refused with 401) and gateway keys (`Authorization: Bearer mgw_...`) work, which is all
tailnet mode (design 5.6) needs. The public path through Cloudflare (hostname `memory.nwlnexus.io`, tunnel route,
Access policy) is #451 and is deliberately absent here.

## Verification after enabling

```sh
kubectl -n memory get deploy,pods,pdb,svc,networkpolicy -l app.kubernetes.io/name=memory-gateway
kubectl -n memory logs deploy/memory-gateway | head
# /readyz from inside the cluster (design acceptance for G10):
kubectl -n memory run curl --rm -i --restart=Never --image=curlimages/curl:8.10.1 --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl:8.10.1","args":["-sS","-m","5","-w","\n%{http_code}\n","http://memory-gateway.memory.svc/readyz"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# An unauthenticated MCP call must be 401 (same pod, POST http://memory-gateway.memory.svc/mcp).
```

Also: the Prometheus target `kubernetes-pods` for the two pods is `up`, `probe_success{job="blackbox-memory-http"}` is
1, and `promtool` accepted the alert rules (`../../observability/tests/check_prometheus.py`).

### LiteLLM

None since olympus-sdk#569: the data-hub LiteLLM is retired and the gateway embeds queries through
`memory-embedder` only (no `LITELLM_BASE_URL`); if the embedder is down, recall degrades to text-only
(`degraded: ["embedder"]`, design 6.3) and `/readyz` does not depend on it.

## Operations

- Admin CLI (create/revoke clients, requeue dead jobs): `kubectl -n memory exec deploy/memory-gateway -- node dist/admin/cli.js --help`.
- Logs are JSON lines (`request_id`, `client_id`, `route`, `status`, `duration_ms`); no bodies, no headers.
- Rotate the role password: see `../README.md` ("Role passwords"); `Secret/memory-gateway` follows
  `memory-stores` on the next ExternalSecret refresh (hourly) and the reloader rolls the pods.
