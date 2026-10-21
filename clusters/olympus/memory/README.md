# memory — data stores for the memory platform

Namespace `memory`. Implements nwlnexus/olympus-sdk#449 (epic #444, spec sections D3, D4
and 5.2). This directory holds the **stores** and the schema (migrations 0001-0004, see below); the
gateway (#450) and workers (#451) come later and add their own manifests.

| Object | What |
|---|---|
| `StatefulSet/postgres` | Postgres 16 + pgvector (`pgvector/pgvector:pg16`, pinned by digest), database `memory`, 50Gi `qnap-iscsi` PVC `data-postgres-0` |
| `StatefulSet/falkordb` | FalkorDB (`falkordb/falkordb:v4.22.2`, pinned by digest), 20Gi `qnap-iscsi` PVC `data-falkordb-0`, RDB + AOF persistence |
| `Service/postgres`, `Service/falkordb` | ClusterIP, ports 5432 / 6379. `*-headless` are the StatefulSet identities. Nothing exposes them outside the cluster |
| `Job/memory-migrate` + `migrations/` | Versioned, idempotent SQL applied in order, ledger in `memory.schema_migrations` |
| `CronJob/postgres-backup`, `CronJob/falkordb-backup` | Nightly 03:00 / 03:15 UTC to PVC `memory-backups` (10Gi, `qnap-nfs`), 14 kept of each |
| `ExternalSecret/memory-stores` | Credentials from 1Password |
| `NetworkPolicy` | Default deny ingress; stores reachable from this namespace and the blackbox-exporter only |

Scheduling is intentionally default (no node pinning). WS12 (olympus-sdk#457) may move the
platform to an `olympus.io/role=agent-services` node.

## Prerequisite: the 1Password item

The ExternalSecret reads a **new** item in vault **Dev**:

- item name: `memory-stores`
- fields: `postgres-password`, `falkordb-password`, `gateway-db-password`,
  `worker-db-password` (concealed; generate each with `openssl rand -hex 24`). The last two
  are the passwords of the Postgres roles `memory_gateway` and `memory_worker` (migration
  0004); the stores themselves only need the first two.

Create it before the PR is merged. Until it exists the Secret `memory-stores` does not,
both StatefulSets wait in `CreateContainerConfigError`, and the `memory` Flux Kustomization
stays not-Ready (nothing depends on it).

`POSTGRES_PASSWORD` is only read when Postgres initialises an empty data directory. To rotate
the Postgres password later: change the 1Password field, then
`kubectl -n memory exec postgres-0 -- psql -U postgres -c "ALTER ROLE postgres PASSWORD '<new>'"`
(FalkorDB re-reads its password on the next pod restart).

## Adding a migration

Migrations are plain SQL files in `migrations/`, named `NNNN_short_description.sql`
(zero-padded, next free number), applied in filename order by `Job/memory-migrate`.

1. Create `migrations/<next number>_<what>.sql` (the next free number is `0005`). It must be **idempotent** (`CREATE ... IF NOT EXISTS`,
   `ADD COLUMN IF NOT EXISTS`, `DO $$ ... $$` guards), because it is run once per database but
   may be replayed by hand or after a restore. Do not put `BEGIN`/`COMMIT` in it: the runner
   wraps each file and its ledger row in one transaction, so a failing file leaves nothing behind.
   Statements that cannot run in a transaction (`CREATE INDEX CONCURRENTLY`) need their own
   mechanism; raise it in the PR.
2. Add the file to the `memory-migrations` generator in `kustomization.yaml` (kustomize does not
   glob). The ConfigMap name carries a content hash, so the Job's pod template changes and
   Flux recreates the Job (`kustomize.toolkit.fluxcd.io/force: enabled`), which re-runs the
   runner. Already-applied versions are skipped.
3. **Never edit an applied migration.** The runner stores each file's sha256 in
   `memory.schema_migrations` and fails the Job if an applied file has changed. Fix forward
   with a new file.

Inspect state: `kubectl -n memory logs job/memory-migrate` and
`kubectl -n memory exec postgres-0 -- psql -U postgres -d memory -c 'SELECT * FROM memory.schema_migrations ORDER BY version'`.

The Job connects as the `postgres` superuser.

### Migrations 0001-0004

| File | What |
|---|---|
| `0001_init.sql` | `vector` extension, schema `memory`, the ledger `memory.schema_migrations` |
| `0002_core.sql` | `client`, `episode`, `fact`, `fact_revision`, `fact_embedding` (vector(768), HNSW), `import_ledger`, `audit_log`, `touch_updated_at()` |
| `0003_queue_and_graph.sql` | `capture_queue` (the durable job queue), `fact_graph_episode`, and the Postgres mirror of the Graphiti graph (`entity`, `entity_edge`, `fact_entity`) |
| `0004_roles.sql` | least-privilege login roles `memory_gateway` and `memory_worker` with their grants (no password in SQL) |

0002-0004 are copied verbatim from the approved contract,
[`docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md`](https://github.com/nwlnexus/olympus-sdk/blob/main/docs/superpowers/specs/2026-10-21-memory-gateway-contract-design.md)
section 3 in olympus-sdk (epic #444, issue #450). That document is the authority for the
tables, the roles' privileges and the queue semantics; do not edit these files, add a new
migration instead. The gateway and the workers connect as `memory_gateway` / `memory_worker`,
never as `postgres`.

### Role passwords

Migration 0004 creates the two roles with `LOGIN` but no password, so until the password step
has run they cannot authenticate. After the migration loop the same Job sets both passwords
from the Secret `memory-stores` (keys `gateway-db-password` and `worker-db-password`, from the
1Password item of the same name):

- Each password goes to `psql` through its **environment** and is read by a `\set` backtick
  (`printf %s "$DB_PW"`), then substituted with `ALTER ROLE :"role" PASSWORD :'pw'`. It is on
  no command line (so not in the process list), not in a SQL file, not in the ConfigMap, and
  never echoed; the Job only logs `password set for role <name>`. The session also sets
  `log_min_duration_statement = -1` and `log_min_error_statement = panic` so the statement
  cannot reach the server log.
- The step is idempotent (`ALTER ROLE ... PASSWORD` can be repeated) and runs on every Job run,
  including runs where every migration was skipped. An empty value fails the Job.
- **Merging before the 1Password fields exist is safe but leaves the Job pending.** The
  ExternalSecret then fails to sync (`SecretSyncedError`; the Secret keeps its existing keys),
  the Job's `secretKeyRef` for the new keys cannot be resolved, and the Job pod sits in
  `CreateContainerConfigError` (`kubectl -n memory describe pod -l app.kubernetes.io/name=memory-migrate`
  says `couldn't find key gateway-db-password`). It does not crash-loop and does not consume
  `backoffLimit`; the new env vars are deliberately **not** `optional: true` (fail closed: an
  optional reference would start the Job with empty passwords, which it rejects, burning
  `backoffLimit` and ending Failed, which only a spec change could retry). Migrations 0002-0004
  are not applied during the wait either, because the container does not start. Once the fields
  exist, the next ExternalSecret refresh (hourly, or
  `kubectl -n memory annotate externalsecret memory-stores force-sync=$(date +%s) --overwrite`)
  creates the keys and the kubelet starts the pod by itself. The stores are unaffected; the
  `memory` Kustomization only health-checks the StatefulSets.
- **Rotating a role password:** change the 1Password field, wait for the Secret to refresh,
  then re-run the Job (`kubectl -n memory delete job memory-migrate`, then
  `flux reconcile kustomization memory -n flux-system`). Running pods that use the old password
  keep working until they reconnect; restart them afterwards.
- To log in as a role from inside the cluster, for example to test grants:
  `kubectl -n memory exec -it postgres-0 -- psql -h postgres -U memory_gateway -d memory`
  (`-h postgres` forces TCP password authentication; type the password at the prompt rather
  than putting it on a command line).

## Backups

Both CronJobs write to the `memory-backups` PVC (`qnap-nfs`), in `postgres/` and `falkordb/`
subdirectories, each keeping the newest 14 files. Files are written under a dot-prefixed temp
name, verified, then renamed; retention runs only after a verified write. The PVC carries
`kustomize.toolkit.fluxcd.io/prune: disabled` because the `qnap-nfs` class has
`reclaimPolicy: Delete` / `archiveOnDelete: false` (deleting the PVC deletes every backup).

Run one on demand: `kubectl -n memory create job --from=cronjob/postgres-backup pg-backup-manual`.

- **Postgres:** `pg_dump --format=custom` of database `memory` to `postgres/memory-<UTC>.dump`.
- **FalkorDB:** `redis-cli --rdb` pulls an RDB snapshot over the network (server-side fork, as
  BGSAVE does) to `falkordb/falkordb-<UTC>.rdb`. This is used instead of `BGSAVE` + file copy
  because the data PVC is ReadWriteOnce and cannot be shared with a second pod. Between backups,
  the data PVC itself holds RDB snapshots plus the AOF.

### Restore Postgres

List the dumps, then restore one with a throwaway Job (restricted-compliant, mounts the backup
PVC read-only). `--clean --if-exists` drops and recreates the objects in the dump inside the
existing `memory` database; stop writers (gateway/workers) first.

```sh
kubectl -n memory run pg-restore --rm -i --restart=Never \
  --image=pgvector/pgvector:pg16@sha256:7b822b0aac60967beb1ea5e576b8602c94c300a157d187f385ae3e0da199b90a \
  --overrides='{
    "spec": {
      "securityContext": {"runAsNonRoot": true, "runAsUser": 999, "runAsGroup": 999,
                          "seccompProfile": {"type": "RuntimeDefault"}},
      "volumes": [{"name": "backup", "persistentVolumeClaim": {"claimName": "memory-backups", "readOnly": true}}],
      "containers": [{
        "name": "pg-restore", "image": "pgvector/pgvector:pg16@sha256:7b822b0aac60967beb1ea5e576b8602c94c300a157d187f385ae3e0da199b90a",
        "stdin": true, "tty": false,
        "command": ["/bin/sh", "-c", "ls -1 /backup/postgres/; pg_restore --clean --if-exists --no-owner -h postgres -U postgres -d memory \"/backup/postgres/$DUMP\""],
        "env": [{"name": "DUMP", "value": "memory-YYYYMMDDTHHMMSSZ.dump"},
                {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "memory-stores", "key": "postgres-password"}}}],
        "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
        "volumeMounts": [{"name": "backup", "mountPath": "/backup", "readOnly": true}]
      }]
    }
  }'
```

Replace `DUMP` with a file from the listing. To rebuild into an empty cluster instead: let the
`memory` Kustomization create the stores and run `memory-migrate` first (creates the extension
and schema), then run the same restore.

### Restore FalkorDB

1. `flux suspend kustomization memory -n flux-system`, then
   `kubectl -n memory scale statefulset falkordb --replicas=0`.
2. With a temporary pod that mounts PVC `data-falkordb-0` and `memory-backups`, delete
   `appendonlydir/` and `dump.rdb` in the data volume and copy the chosen
   `falkordb/falkordb-<UTC>.rdb` to `dump.rdb` there (owner uid/gid 999).
3. Start a temporary `redis-server --appendonly no --dir <data> --loadmodule ...falkordb.so`
   (same image) so the RDB is loaded, run `CONFIG SET appendonly yes`, wait for
   `aof_rewrite_in_progress:0` in `INFO persistence`, then `SHUTDOWN`.
4. `kubectl -n memory scale statefulset falkordb --replicas=1` and
   `flux resume kustomization memory -n flux-system`.

(A Redis 7+ server started with `appendonly yes` and no AOF present may come up empty instead of
loading `dump.rdb`, which is why step 3 converts through a temporary AOF-off instance.) This procedure has not been exercised in the
cluster; rehearse it once after the first backup exists.

## Growing a volume

`qnap-iscsi` allows expansion and `reclaimPolicy: Retain`. StatefulSet `volumeClaimTemplates` are
immutable, so patch the live PVC instead and leave the template alone:

```sh
kubectl -n memory patch pvc data-postgres-0 -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
```

Alert `MemoryStorePVCFillingUp` fires at 80% for 30m.

## Network

Default-deny ingress for the namespace. Postgres and FalkorDB accept connections from pods in
`memory` and from the blackbox-exporter pod in `observability`. Egress is unrestricted. Note
that default-deny also covers future pods here: the gateway (#450) needs its own allow rules,
including any from the Tailscale/cloudflared proxies that front it.

## Monitoring

The cluster runs the community `prometheus` chart without the Prometheus operator, so
ServiceMonitor/PrometheusRule objects would be inert. Instead
`../observability/prometheus-helmrelease.yaml` has a `blackbox-memory-tcp` scrape job
(tcp_connect to `postgres.memory.svc:5432` and `falkordb.memory.svc:6379` through the
blackbox-exporter) and a `memory` rule group: `MemoryStoreDown`, `MemoryStorePVCFillingUp`,
`MemoryBackupStale`. Queue-age alerts come with the capture queue.
