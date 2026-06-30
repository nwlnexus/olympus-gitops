# Runbook — bulk claude-mem → mem0 migration (categorization-off mode)

Categorization is a global server toggle (`DISABLE_CATEGORIZATION`, gated in a
SQLAlchemy `after_insert`/`after_update` listener). There is no per-request form
yet (that is Tier 2). For bulk migration, run with categorization OFF: with the
migrator's `infer:false`, each add then touches only `nomic-embed-text`, dropping
warm add latency from ~0.85-2.6s to ~0.1s. The original 11,578-record migration
ran categorization-off, so historical records already have no categories — this
keeps the store consistent.

## Procedure

1. Flip categorization OFF in `clusters/olympus/mem0/deployment.yaml`:
   set `DISABLE_CATEGORIZATION` value `"true"`, commit + push, then:
   `flux --context olympus reconcile kustomization mem0 --with-source`
   Wait for the rollout: `kubectl --context olympus -n mem0 rollout status deploy/openmemory`

2. Verify categorization is off (a single add fires ONLY /api/embed, no
   /v1/chat/completions). Port-forward and add one tagged probe row:
   ```
   POD=$(kubectl --context olympus -n mem0 get pod -l app=openmemory -o jsonpath='{.items[0].metadata.name}')
   kubectl --context olympus -n mem0 port-forward pod/$POD 18765:8765 &
   curl -s -w '\n%{time_total}s\n' -X POST http://127.0.0.1:18765/api/v1/memories/ \
     -H 'Content-Type: application/json' \
     -d '{"user_id":"mnemosyne","text":"runbook probe","infer":false,"metadata":{"source":"runbook-probe"}}'
   kubectl --context olympus -n mem0 logs $POD --since=30s | grep -E "api/embed|chat/completions"
   ```
   Expected: latency ~0.1s; logs show `api/embed` and NO `chat/completions`.

3. Run the migration on each host (now fast + self-healing; resumes from checkpoint):
   `mem0ctl migrate --db ~/.claude-mem/claude-mem.db`

4. Flip categorization BACK ON: set `DISABLE_CATEGORIZATION` value `"false"`,
   commit + push, then `flux --context olympus reconcile kustomization mem0 --with-source`.
   Verify a fresh add again fires `/v1/chat/completions` (categorization restored).

## Caveat
While OFF, interactive adds also skip categorization. Keep the window short and
do not leave it OFF (it is not the steady-state default).
