# ingress-discovery (issue #117)

Phase-4 GitOps deployment for the **ingress-discovery** controller. The controller
watches Traefik `IngressRoute` objects cluster-wide, derives launcher cards for the
ones opted in via `launcher.olympus.io/*` annotations, and **publishes** them to
Hermes (a Cloudflare Worker, NOT in-cluster) at `https://api.nwlnexus.net/graphql`.

Controller code + image ship from **olympus-sdk** (`packages/ingress-discovery`).
This directory is manifests only.

- Image: `ghcr.io/nwlnexus/ingress-discovery:8977a56`
  (digest `sha256:1e439266b0d70f2efa2359f233dfd84cc5a0003ec7a300885951475006717f1a`)
- Namespace: `ingress-discovery`
- Replicas: 1 (leader-elected via a `coordination.k8s.io` Lease; safe to bump to 2 for HA)
- Health: `GET /healthz` on port 8080 (liveness + readiness; not gated on leadership)

## Operator prerequisites — REQUIRED before merge / deploy

Merging this branch deploys to the live `olympus` cluster via Flux. Do ALL of the
following first, or the controller will start, fail to publish (401), and log errors.

1. **Mint a Hermes machine token for the controller.**
   In IRIS (Access → Tokens) or via the GraphQL `issueMachineToken` mutation, mint a
   token that carries the `publish:app-launchers` capability. Record both the **token
   value** (shown once) and its **token id**.

2. **Point Hermes at that token's id and redeploy Hermes.**
   Set the Hermes Worker secret `APP_LAUNCHER_PUBLISH_TOKEN_ID` to the id from step 1
   (`wrangler secret put APP_LAUNCHER_PUBLISH_TOKEN_ID`), then redeploy Hermes so the
   `publishAppLauncherSnapshot` mutation accepts the controller's bearer token.

3. **Create the 1Password item the ExternalSecret reads.**
   This repo's ExternalSecrets use the **1Password Connect** provider
   (`onepassword-connect` ClusterSecretStore, vault `Dev` only) — addressed by item
   name + field, NOT `op://` URIs. Create:

   - Vault: **Dev**
   - Item: **`ingress-discovery`**
   - Field: **`hermes-publish-token`** = the token **value** from step 1

   `externalsecret.yaml` syncs this into the `ingress-discovery-credentials` Secret,
   which the Deployment mounts as `HERMES_PUBLISH_TOKEN`.

   > The private-image pull secret (`ghcr-pull`) reuses the existing 1Password item
   > `gh-pull-secret` (vault Dev) — no new item needed for image pulls.

4. **Confirm publish target.** The controller publishes to `api.nwlnexus.net`
   (set as `HERMES_URL=https://api.nwlnexus.net/graphql` in `deployment.yaml`).

## Token rotation

`HERMES_PUBLISH_TOKEN` is rotated by updating the `hermes-publish-token` field on the
1Password `ingress-discovery` item (ExternalSecret refreshInterval is 1h) and the
corresponding `APP_LAUNCHER_PUBLISH_TOKEN_ID` in Hermes if a new token id is issued.

## Controller env (set by deployment.yaml)

| Var | Value | Source |
|---|---|---|
| `HERMES_URL` | `https://api.nwlnexus.net/graphql` | plain env |
| `HERMES_PUBLISH_TOKEN` | (the token) | Secret `ingress-discovery-credentials` |
| `LEASE_NAMESPACE` | `ingress-discovery` | downward API `metadata.namespace` |
| `POD_NAME` | pod name | downward API `metadata.name` |
| `HEALTH_PORT` | `8080` | plain env |
| `RUST_LOG` | `info` | plain env (read by tracing, not Config) |

Defaults left implicit (controller defaults): `RESYNC_INTERVAL_SECS=300`,
`LEASE_NAME=ingress-discovery-leader`.

## Opting an app into the launcher

Add annotations to its Traefik `IngressRoute`:

```yaml
launcher.olympus.io/enabled: "true"          # required opt-in
launcher.olympus.io/display-name: "Grafana"  # optional (default: humanized name)
launcher.olympus.io/group: "Observability"   # optional
launcher.olympus.io/icon: "gauge"            # optional lucide icon name
```

Canary set in this PR: **grafana** (`observability`) and **traefik-dashboard** (`traefik`).
