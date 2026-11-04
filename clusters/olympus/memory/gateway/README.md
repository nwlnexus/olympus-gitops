# memory-gateway — deployment (olympus-sdk#450 task G10, epic #444)

The TypeScript gateway (MCP + REST) in front of the Postgres store in `..`. Design:
[`2026-10-21-memory-gateway-contract-design.md`](https://github.com/nwlnexus/olympus-sdk/blob/main/docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md)
sections 5.6, 6.1 and 9. Image: `ghcr.io/nwlnexus/memory-gateway`, built by
`.github/workflows/memory-gateway.yml` in olympus-sdk.

| File | What |
|---|---|
| `gateway.yaml` | `ConfigMap/memory-gateway-config`, `Service/memory-gateway` (80 -> 8080), `PodDisruptionBudget`, `Deployment/memory-gateway` (2 replicas) |
| `tailscale-service.yaml` | `Service/memory-ts`, LoadBalancer class `tailscale`, tailnet host `memory` (port 80 -> 8080). No Funnel |
| `externalsecret.yaml` | `Secret/memory-gateway`: `DATABASE_URL` (role `memory_gateway`), mounted as a file |
| `ghcr-pull-externalsecret.yaml` | `Secret/ghcr-pull` (image pull; the package is private) |
| `networkpolicy.yaml` | `allow-gateway-ingress`: 8080 from the Tailscale proxy pod, the cloudflared pods and the blackbox exporter, 9090 from Prometheus. `allow-gateway-egress`: DNS, Postgres 5432, embedder 8080, TCP 443 to Cloudflare's IPv4 ranges (Access JWKS); each destination's evidence is in the file |

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
| `MEMORY_ACCESS_TEAM_DOMAIN` (`https://<team>.cloudflareaccess.com`) and `MEMORY_ACCESS_AUD` | `TODO(olympus-sdk#736)`, commented out in the ConfigMap in `gateway.yaml` | printed by olympus-infra `playbooks/push/cloudflare-access.yml`; uncomment **both** (or neither), see "Public path" |

With the two Access values unset the gateway starts, the Access-JWT path is disabled (a request carrying only
an Access JWT is refused with 401) and gateway keys (`Authorization: Bearer mgw_...`) work, which is all
tailnet mode (design 5.6) needs.

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

## Public path: https://memory.nwlnexus.io (olympus-sdk#736)

```
client --TLS--> Cloudflare edge (Access: allow-owner | service-auth) --tunnel--> cloudflared pod
       --http, in cluster--> Service memory-gateway:80 -> pod :8080 (verifies the Access JWT, design 5.2)
```

- **Routing.** One hostname rule on the remotely managed `compute-hub` tunnel (its ingress lives in the
  Cloudflare API, see `../../cloudflared/configmap.yaml`), straight to `http://memory-gateway.memory.svc.cluster.local:80`,
  and a proxied CNAME, both written by olympus-infra `roles/cloudflare-access` (no IngressRoute, no
  external-dns record). Not through Traefik: Traefik is a LAN `LoadBalancer`, so a Traefik route would make the
  gateway reachable from the LAN with `Host: memory.nwlnexus.io`, past Cloudflare; this way only the
  cloudflared pods are admitted (`networkpolicy.yaml`). The tunnel's catch-all (Traefik) and every other rule
  stay as they are, so the issue's "catch-all 404" does not apply to this shared tunnel.
- **Access.** Application `memory` on the bare host (every path, so `/healthz` and its version are behind
  Access, F12), policies exactly `memory-allow-owner` and `memory-service-auth`, no Bypass; Managed OAuth with
  dynamic client registration for `https://claude.ai/*`. With Managed OAuth on, a non-browser request without
  credentials gets **401** with a `WWW-Authenticate` header pointing at Access (browsers get the 302 login).

### Enable sequence

Merge order: this directory's egress/ingress policies (safe alone: nothing routes from cloudflared until the
tunnel rule exists, and every egress destination is listed with its evidence) -> olympus-sdk #735 deployed
(the gateway requires a JWT on the public Host) -> then:

1. Owner: the Cloudflare API token and the e-mail (olympus-sdk `docs/runbooks/memory-access-service-tokens.md`,
   "Owner checklist").
2. olympus-infra: `ansible-playbook playbooks/push/cloudflare-access.yml --check -e '{"cloudflare_access_owner_emails": ["<owner>"]}'`,
   read the plan, run it again without `--check`. It prints `MEMORY_ACCESS_TEAM_DOMAIN`, `MEMORY_ACCESS_AUD` and
   each token's client id.
3. This repo, one PR: uncomment the two values in `gateway.yaml`. The reloader rolls the pods; `/readyz` now
   also waits for the first JWKS fetch, which the egress rule to Cloudflare's ranges allows.
4. Gateway client rows (admin CLI below): one `access_service_token` row per token
   (`--id memory-<host, lower-case> --common-name <client id> --scopes ''`), and the owner's `access_sso` row for claude.ai
   with the default scopes `read,write` only (no forget, no admin; F11).
5. nix-darwin-hm: hosts that need the public path set `d.memory.mode = "public"` or `d.memory.fallback = true`
   and switch (fetch-secrets reads `op://Dev/memory-access-tokens/<host>-id|secret`).

### Verification (the #571 / #736 Done-when checks)

Command blocks carry no `#` comments (zsh does not take them interactively); each step says what to expect.

1. No credentials. Access answers, the gateway never does: the status is 401 with a `WWW-Authenticate` header
   pointing at the team domain (Managed OAuth; 302/403 without it) and there is **no** `X-Request-Id`, which
   every gateway response carries. The same holds for `/healthz` (F12).

   ```sh
   curl -sI https://memory.nwlnexus.io/mcp | grep -iE '^(HTTP/|www-authenticate|location|x-request-id)'
   curl -sI https://memory.nwlnexus.io/healthz | grep -iE '^(HTTP/|x-request-id)'
   ```

2. A service token (from a host in public mode or with the fallback): 200 from the gateway, with an
   `X-Request-Id`. Then `claude mcp list` on that host shows `memory` connected.

   ```sh
   curl -sS -o /dev/null -D - -w '%{http_code}\n' https://memory.nwlnexus.io/readyz -H "CF-Access-Client-Id: $(cat ~/.config/memory/cf-access-client-id)" -H "CF-Access-Client-Secret: $(cat ~/.config/memory/cf-access-client-secret)" | grep -iE '^x-request-id|^[0-9]{3}$'
   ```

3. A service token without a gateway key on `POST /mcp`: Access lets it through and the gateway refuses it
   (401/403 with an `X-Request-Id`; #735).

4. Egress applied and the gateway healthy. Expect the three policies listed, `readyz 200`, `embedder 200`,
   `jwks 200` (only once the Access values are set), `blocked as expected` for an arbitrary internet host, and
   a count of 0 connection errors in each worker's log.

   ```sh
   kubectl -n memory get networkpolicy allow-gateway-egress allow-worker-egress allow-worker-extract-litellm
   kubectl -n memory exec deploy/memory-gateway -- node -e "fetch('http://127.0.0.1:8080/readyz').then(r=>console.log('readyz',r.status))"
   kubectl -n memory exec deploy/memory-gateway -- node -e "fetch('http://memory-embedder.memory.svc/health').then(r=>console.log('embedder',r.status))"
   kubectl -n memory exec deploy/memory-gateway -- node -e "fetch(process.env.MEMORY_ACCESS_TEAM_DOMAIN+'/cdn-cgi/access/certs').then(r=>console.log('jwks',r.status))"
   kubectl -n memory exec deploy/memory-gateway -- node -e "fetch('https://example.com',{signal:AbortSignal.timeout(5000)}).then(r=>console.log('UNEXPECTED',r.status),e=>console.log('blocked as expected'))"
   kubectl -n memory logs deploy/memory-worker-extract --since=15m | grep -ciE 'connect(ion)? ?(error|refused)|timed? ?out'
   kubectl -n memory logs deploy/memory-worker-embed --since=15m | grep -ciE 'connect(ion)? ?(error|refused)|timed? ?out'
   ```

Plus: `probe_success{job="blackbox-memory-http"}` stays 1, `MemoryQueueBacklog*` stays quiet, and
`memory_*_embedder*` metrics show no new errors after the policies apply.

### Rollback

- Public path only: olympus-infra `-e cloudflare_access_tunnel_enabled=false` removes the tunnel rule (the
  host then falls to the Traefik catch-all, which has no route for it: 404 behind Access).
- Egress: revert the policy commit; Flux prunes the NetworkPolicies and egress is open again.
- Access values: comment them out again (JWT path off, tailnet unaffected).

### Public-path TLS for the in-cluster hop (open: owner decision)

The owner accepted F6 (plaintext in-cluster hop) for the tailnet path only. The public path has the same
hop, cloudflared pod -> gateway pod over `http://`, carrying the Access JWT and, in public mode, the
long-lived `mgw_` key. Pods on different nodes talk over flannel VXLAN on the LAN, unencrypted. Options:

| | Option | Effort | Notes |
|---|---|---|---|
| A | TLS sidecar in the gateway pod (e.g. ghostunnel) on :8443 -> 127.0.0.1:8080, cert from cert-manager (a namespaced CA `Issuer`, SAN `memory-gateway.memory.svc.cluster.local`); tunnel rule `https://...:8443` with `originRequest.caPool` (CA mounted into cloudflared) and `originServerName` | S-M: gitops only, one more pinned image, cloudflared volume | no gateway code change; NetworkPolicy admits cloudflared on 8443 only |
| B | Gateway terminates TLS itself (Node `https.createServer`, cert files from the same cert-manager CA) | M: olympus-sdk code + tests, then A's cloudflared/tunnel steps | one process; also lets the tailnet path use TLS later |
| C | Encrypt all node-to-node pod traffic: k3s `flannel-backend: wireguard-native` | M-L: cluster-wide, every node's k3s restarted one at a time | covers every namespace; same-node traffic stays plain (root on the node only) |
| D | Accept for the public path too (written owner decision) | none | exposure: LAN sniffing of cross-node VXLAN, root on a node |


- Admin CLI (create/revoke clients, requeue dead jobs): `kubectl -n memory exec deploy/memory-gateway -- node dist/admin/cli.js --help`.
- Logs are JSON lines (`request_id`, `client_id`, `route`, `status`, `duration_ms`); no bodies, no headers.
- Rotate the role password: see `../README.md` ("Role passwords"); `Secret/memory-gateway` follows
  `memory-stores` on the next ExternalSecret refresh (hourly) and the reloader rolls the pods.
