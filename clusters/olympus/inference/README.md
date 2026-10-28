# inference: LiteLLM in the cluster (olympus-sdk#569, HW11)

The cluster's only LLM routing layer (spec decision H9; owner scope change 2026-10-28: **no cloud tier**).
Clients call capability aliases; each alias goes to the A9 first and falls back to data-hub.

| Alias | Primary: A9 (`100.89.177.55`) | Fallback: data-hub (`100.95.232.41`) | Clients |
|---|---|---|---|
| `memory-extract` | `:8081` qwen3.6-27b | `:8081` qwen3.6-27b (group `memory-extract-datahub`) | memory workers |
| `coder-heavy` | `:8081` qwen3.6-27b | `:8081` qwen3.6-27b (`coder-heavy-datahub`) | #197 executor (not built yet) |
| `coder-light` | `:8082` qwen2.5-7b-instruct | `:8082` qwen2.5-7b-instruct (`coder-light-datahub`) | #197 executor (not built yet) |

Not here: `memory-embed` (the gateway and workers embed through `memory/embedder`), `coder-cloud` (no cloud tier).

| File | What |
|---|---|
| `litellm-config.yaml` | model list, fallbacks, retries, timeouts, Prometheus callback (ConfigMap `litellm-config-<hash>`) |
| `custom_auth.py` | per-client keys without a database (absorbs olympus-sdk#490) |
| `litellm.yaml` | `Service/litellm` (:4000), `PodDisruptionBudget/litellm`, `Deployment/litellm` (2 replicas, agent-services onodes) |
| `externalsecret.yaml` | `Secret/litellm` (master key) and `Secret/litellm-client-keys` (one file per client) |
| `networkpolicy.yaml` | default deny; in: memory-worker-extract, Prometheus, blackbox; out: CoreDNS and the two backends on 8081-8082 |

URL for clients: `http://litellm.inference.svc:4000/v1`.

## Routing, retries, timeouts

- Ordered fallback per alias (`router_settings.fallbacks`): A9 group, then its data-hub twin, then the error.
- One immediate retry on the same deployment for connection errors and 5xx (llama-server answers 503 while it
  loads, 3-7 s after a restart); no retry on timeouts. A refused A9 costs about 2.5 s before data-hub answers
  (measured locally with this image and config).
- Timeouts: A9 300 s, data-hub 210 s; together below the worker's 540 s (`MEMORY_EXTRACT_TIMEOUT_SECONDS`), so
  LiteLLM always answers before the worker gives up (#591). A9 p50 11.6 s / p95 16 s per golden episode (#530).
- Readiness is `/health/readiness` and liveness `/health/liveliness`: neither calls a backend, so a backend
  outage never empties the Service. `/health` calls every model and is not used as a probe.

## Per-client keys

`custom_auth.py` maps the presented bearer key to a client by comparing it with the files in
`/etc/litellm/client-keys` (file name = client) and checks the requested alias against
`LITELLM_CLIENT_SCOPES` (`litellm.yaml`). Unknown key: 401. Alias or route outside the client's scope: 403.
Only inference routes and the model list are open; no admin, UI or key management (there is no database).
Metrics identify the client as `api_key_alias`. A key rotated in 1Password is picked up after the ESO refresh
(1 h, or `kubectl annotate externalsecret ... force-sync=$(date +%s)`) without a restart.

**Keys:** 1Password item `litellm-cluster` (vault Dev): `master-key` (Secret `litellm`) and `memory-workers-key`
(file `memory-workers`; the same field feeds `../memory/workers/externalsecret.yaml`); later `executor-key`.
During the switch from the old key, the file `memory-workers.previous` (from `litellm` / `master-key`) is a second
accepted key of the same client (`<client>.<suffix>` files, `custom_auth.py`); remove it once the workers run with
the new key.

## Metrics and alerts

Scraped by the dedicated job `inference-litellm` (`../observability/prometheus-helmrelease.yaml`), which drops
`hashed_api_key` (LiteLLM writes the raw presented key into it when it refuses a request), `client_ip` and
`user_agent`. Probes: job `blackbox-inference-http` (LiteLLM readiness, A9 `:8081`/`:8082` `/health`); data-hub
backends are probed by `blackbox-datahub-http`. Alerts (group `inference`, tests in
`../observability/tests/inference-alerts.test.yaml`): `LiteLLMDown`, `InferenceBackendDown`,
`InferenceAllBackendsDown`, `LiteLLMFailoverActive`, `LiteLLMFallbackFailed`, `LiteLLMHighErrorRate`.

Failover is visible as `litellm_deployment_successful_fallbacks_total{requested_model, fallback_model}` and
`litellm_deployment_failure_responses_total{model_id, exception_class}`, and on the backends as
`llamacpp:requests_processing` moving from the A9 to data-hub.

## Verify

```sh
kubectl -n inference get pods -o wide            # 2/2 Running on onode-0636e4 / onode-062caa
kubectl -n inference logs deploy/litellm | grep -m1 "Uvicorn running"
# from a memory worker pod (the only client the NetworkPolicy admits):
kubectl -n memory exec deploy/memory-worker-extract -- python -c \
  'import urllib.request;print(urllib.request.urlopen("http://litellm.inference.svc:4000/health/readiness").read())'
```

Roll back: remove `flux-kustomizations/inference.yaml` from `../kustomization.yaml` (prune deletes the
namespace's objects); clients still on the data-hub URL are unaffected.
