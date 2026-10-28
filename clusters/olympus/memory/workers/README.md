# memory-workers — deployment (olympus-sdk#453, epic #444)

The queue workers of the memory gateway: they take `extract` and `embed` jobs from the Postgres queue
(`memory.capture_queue`), call the cluster LiteLLM (`../../inference`: A9, then data-hub) and write facts and embeddings back. Design:
[`2026-10-21-memory-gateway-contract-design.md`](https://github.com/nwlnexus/olympus-sdk/blob/main/docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md)
sections 3.4, 8 and 9. Code, configuration reference and image: `packages/memory-workers` in olympus-sdk
(`README.md` there lists every setting), published as `ghcr.io/nwlnexus/memory-workers` by
`.github/workflows/memory-workers.yml`. **Version 1 has two stages and no graph.**

| File | What |
|---|---|
| `workers.yaml` | `Deployment/memory-worker-extract` (1 replica), `Deployment/memory-worker-embed` (2 replicas), `PodDisruptionBudget/memory-worker-embed` |
| `workers-config.env` | the settings: `kustomization.yaml` generates `ConfigMap/memory-workers-config-<hash>` from it, so a change rolls both Deployments on reconcile (olympus-sdk#591) |
| `externalsecret.yaml` | `Secret/memory-workers`: `DATABASE_URL` (role `memory_worker`) and `LITELLM_API_KEY`, mounted as files (`*_FILE`) |
| `networkpolicy.yaml` | `allow-worker-ingress`: 9090 from Prometheus only |
| `kustomization.yaml` | the three files above |

Not here, on purpose:

- **`ghcr-pull`** (image pull Secret): already created in this namespace by `../gateway/ghcr-pull-externalsecret.yaml`;
  two ExternalSecrets must not own the same Secret. This is why the Flux Kustomization `memory-workers`
  `dependsOn: memory-gateway`.
- **A Service**: nothing connects to a worker. Prometheus scrapes the pods directly (annotations, below).
- **Postgres access rule**: `../networkpolicy.yaml` `allow-store-ingress` admits every pod of the namespace
  (`from: podSelector: {}`) on 5432, which includes the worker pods. Verified, no change needed.

## What runs

| | `memory-worker-extract` | `memory-worker-embed` |
|---|---|---|
| args | `--stage extract` | `--stage embed` |
| replicas | **1** (the 27B llama-server is single-slot) | 2, preferred anti-affinity across nodes |
| claim loops x batch | 1 x 1 | 4 x 4 per pod (a batch is one `/embeddings` request) |
| rollout | `Recreate` (never two extractors at once) | rolling, `maxUnavailable: 0`, `maxSurge: 1` |
| requests / limit | 100m, 256Mi / 1Gi | 100m, 192Mi / 512Mi |
| LiteLLM alias | `memory-extract` | `memory-embed` |

Both: uid/gid 10001, Pod Security `restricted`, read-only root filesystem with an `emptyDir` on `/tmp`, all
capabilities dropped, seccomp `RuntimeDefault`, no service account token. Port 9090 (`metrics`) serves
`/metrics`, `/healthz` (startup and liveness: the worker loop is alive, no database involved, so an outage of
Postgres or LiteLLM never restarts a pod) and `/readyz` (readiness: last database round trip is recent and
the worker is not shutting down). Scrape annotations `prometheus.io/scrape|port|path` feed the `kubernetes-pods`
job of the cluster's Prometheus, the same way the gateway is scraped.

`terminationGracePeriodSeconds: 30`. On SIGTERM a worker stops claiming and gives the job in flight
`MEMORY_WORKER_SHUTDOWN_GRACE_SECONDS` (default 20) to commit; after that the job is put back with `Q-RELEASE`
(the attempt is not counted) and the process exits 0. The pod's grace period must stay above the worker's.
A restart or rollout therefore never loses a job, at worst an extraction restarts from scratch.

Settings live in `workers-config.env` (generated `ConfigMap/memory-workers-config-<hash>`) (shared keys through `envFrom`, the four per-stage keys
`extract-*` / `embed-*` through `configMapKeyRef`). Anything not listed there keeps the worker default (README of
the package: leases extract 600 s / embed 120 s, job timeout 1500 s / 90 s, extract window all day). Changing the
ConfigMap or the Secret rolls the pods (stakater reloader). `MEMORY_GRAPH_ENABLED=false` stays until the Graphiti
ingest worker exists, otherwise `graph_ingest` jobs would pile up and trip the queue backlog alerts.

Connections: each pod opens `concurrency + 4` Postgres connections as `memory_worker` (5 for extract, 8 per embed
pod), 21 in total against `max_connections = 100` (the gateway uses its own pool).

## Why a separate Flux Kustomization

Like the gateway: `../kustomization.yaml` (`memory`, which health-checks the StatefulSets) does not include this
directory. `../../flux-kustomizations/memory-workers.yaml` (`dependsOn: memory, memory-gateway`, health checks
both Deployments, `prune: true`) deploys it, so a bad worker rollout, an unpullable image or a missing 1Password
item can only make `memory-workers` unhealthy, never the stores or the gateway.

**Roll back / disable:** remove `  - flux-kustomizations/memory-workers.yaml` from `../../kustomization.yaml`
(`prune: true` then deletes the objects; queued jobs stay in Postgres and are processed after the next deploy).

## Prerequisites (1Password, vault Dev; all exist today)

- `memory-stores` field `worker-db-password` (the migrate Job already set the role's password from it);
- `litellm-cluster` field `memory-workers-key` (the workers' own key for the cluster LiteLLM, olympus-sdk#569);
- `gh-pull-secret` (via the gateway's `ghcr-pull`).

Missing items leave the pods in `ContainerCreating` (the Secret volume cannot mount); nothing else is hurt.

## First-run verification

```sh
flux get kustomization memory-workers
kubectl -n memory get deploy,pods,pdb,networkpolicy -l app.kubernetes.io/part-of=memory,app.kubernetes.io/component=worker
kubectl -n memory get externalsecret memory-workers                 # SecretSynced / Ready
kubectl -n memory logs deploy/memory-worker-extract | head          # JSON lines: "worker starting", config WITHOUT secrets
kubectl -n memory logs deploy/memory-worker-embed | head
# Prometheus: both targets up (job kubernetes-pods), series present (primed to 0 at start):
#   up{job="kubernetes-pods",namespace="memory",pod=~"memory-worker-.*"}
#   memory_worker_jobs_total{stage=~"extract|embed"}
# Endpoints from inside the cluster (pod IP from `kubectl -n memory get pods -o wide`; only Prometheus may connect,
# so use a port-forward instead of a curl pod):
kubectl -n memory port-forward deploy/memory-worker-embed 9090:9090 &
curl -s localhost:9090/readyz; curl -s localhost:9090/metrics | grep '^memory_worker_' | head; kill %1
```

End to end: capture something through the gateway and watch the queue drain and facts appear.

```sh
kubectl -n memory exec deploy/memory-gateway -- node dist/admin/cli.js queue stats      # pending/running/dead per stage
kubectl -n memory exec postgres-0 -- psql -U postgres -d memory -c \
  "select stage, state, count(*) from memory.capture_queue group by 1,2 order by 1,2"
```

Expect `extract` jobs to go `pending -> running -> done` (tens of seconds each, the model is local), one
`embed` job per inserted fact right after, and `memory_worker_facts_written_total` to grow.
If LiteLLM is unreachable from ns `memory` the jobs go `retry` (`memory_worker_llm_requests_total{outcome="network_error"}`)
with exponential backoff; they are not lost. The pod-to-LiteLLM check of `../gateway/README.md` ("T-TS") covers it.

## Pausing extraction (model maintenance on data-hub)

Extraction is the only stage that needs the GPU model; the embed workers keep running for jobs already queued.

```sh
# Flux owns spec.replicas and would put it back to 1 on the next reconcile (every 10m): suspend first.
flux suspend kustomization memory-workers -n flux-system
kubectl -n memory scale deploy/memory-worker-extract --replicas=0
# ... maintenance on data-hub ...
kubectl -n memory scale deploy/memory-worker-extract --replicas=1
flux resume kustomization memory-workers -n flux-system
```

(For a pause longer than a day, commit `replicas: 0` in `workers.yaml` instead, and revert it afterwards.)
Scaling to 0 is safe: SIGTERM releases the job in flight without counting an attempt, `pending` jobs just wait,
and a job whose lease runs out is returned by the reaper that the embed workers also run.

Effect on alerts (they come from the gateway's queue gauges, `max by (stage)`):

- `MemoryQueueBacklogOld` (warning) fires for stage `extract` once the oldest pending job is older than 4h and
  stays so for 30m, i.e. after about **4.5 hours** of pause with traffic. Longer pauses will page it.
- `MemoryQueueBacklogStuck` (critical) fires after about **24.5 hours**.
- `MemoryCaptureStalled` is unaffected (capture still works; only processing waits).
- Jobs queued during the pause are processed in priority order when the worker comes back; nothing is dropped.

Silence `MemoryQueueBacklogOld` for `stage="extract"` in Alertmanager for planned pauses that will exceed 4h.
To pause only the backlog of bulk imports and not live captures, set `MEMORY_EXTRACT_WINDOW` (hours UTC in which
`priority >= 200` jobs are claimed; live jobs always run) in the ConfigMap instead of scaling to 0.

## Rotating the database password

The password is `worker-db-password` in the 1Password item `memory-stores`; the role's password in Postgres is
set by Job/memory-migrate (`ALTER ROLE`), so both have to move together, in this order:

1. Change the field in 1Password. Wait for `Secret/memory-stores` to refresh (hourly, or
   `kubectl -n memory annotate externalsecret memory-stores force-sync=$(date +%s) --overwrite`).
2. Re-run the migrate Job: `kubectl -n memory delete job memory-migrate`, then
   `flux reconcile kustomization memory -n flux-system` (it re-applies the password to the role; idempotent).
3. Refresh `Secret/memory-workers` the same way
   (`kubectl -n memory annotate externalsecret memory-workers force-sync=$(date +%s) --overwrite`);
   the reloader then rolls the pods. If it did not, restart them:
   `kubectl -n memory rollout restart deploy/memory-worker-extract deploy/memory-worker-embed`.

Between step 2 and the restart the running workers keep their open connections; a worker that has to open a new
connection with the old password fails the claim and retries (liveness does not involve the database, so the pod
is not restarted by it). Jobs in flight are safe either way: a failed write leaves the lease to expire and the
job is retried.
