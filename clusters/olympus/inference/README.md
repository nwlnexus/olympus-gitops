# inference: LiteLLM in the cluster (olympus-sdk#569, HW11)

The cluster's only LLM routing layer (spec decision H9; owner scope change 2026-10-28: **no cloud tier**).
Clients call capability aliases; each alias goes to the A9 first and falls back to data-hub.

| Alias | Primary: A9 (`100.89.177.55`) | Fallback: data-hub (`100.95.232.41`) | Clients |
|---|---|---|---|
| `memory-extract` | `:8081` qwen3.6-27b | `:8081` qwen3.6-27b (group `memory-extract-datahub`) | memory workers |
| `coder-heavy` | `:8085` qwen3.6-27b-coder (own process, 64k) | `:8081` qwen3.6-27b (`coder-heavy-datahub`) | #197 executor (olympus-kvm runners; key pending, #642) |
| `coder-medium` | `:8084` qwen3.6-35b-a3b (MoE, 3B active, 64k) | `:8081` qwen3.6-27b (`coder-medium-datahub`; data-hub has no 35B) | #197 executor (olympus-kvm runners; key pending, #642) |
| `coder-light` | `:8082` qwen3.5-9b | `:8082` qwen2.5-7b-instruct (`coder-light-datahub`, fallback only) | #197 executor (olympus-kvm runners; key pending, #642) |

Not here: `memory-embed` (the gateway and workers embed through `memory/embedder`), `coder-cloud` (no cloud tier).

| File | What |
|---|---|
| `litellm-config.yaml` | model list, fallbacks, retries, timeouts, Prometheus callback (ConfigMap `litellm-config-<hash>`) |
| `custom_auth.py` | per-client keys without a database (absorbs olympus-sdk#490) |
| `litellm.yaml` | `Service/litellm` (:4000), `PodDisruptionBudget/litellm`, `Deployment/litellm` (2 replicas, agent-services onodes) |
| `externalsecret.yaml` | `Secret/litellm` (master key) and `Secret/litellm-client-keys` (one file per client) |
| `networkpolicy.yaml` | default deny; in: memory-worker-extract, Prometheus, blackbox; out: CoreDNS, both backends on 8081-8082 and the A9 on 8084-8085 |

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
(file `memory-workers`; the same field feeds `../memory/workers/externalsecret.yaml`); `executor-key` (#642, added by the
owner; ExternalSecret `litellm-executor-key` -> Secret `litellm-executor-key`, mounted as file `executor` through a projected
volume with `optional: true`, kept apart so a missing field never affects the other two ExternalSecrets). Limits for the
executor (`LITELLM_CLIENT_LIMITS`): 60 requests/min and 3 parallel requests per replica.

Who may call LiteLLM (ingress 4000): memory workers (`memory`), Prometheus and blackbox (`observability`), `olympus-kvm`
runner pods (`arc-runners`, label `olympus.io/ci-kvm`; executor scope `coder-*` only).
For a rotation, add a file `<client>.<suffix>` (for example `memory-workers.previous`) to the Secret: `custom_auth.py`
accepts it as a second key of the same client until it is removed.

## Metrics and alerts

Scraped by the dedicated job `inference-litellm` (`../observability/prometheus-helmrelease.yaml`), which drops
`hashed_api_key` (LiteLLM writes the raw presented key into it when it refuses a request), `client_ip` and
`user_agent`. Probes: job `blackbox-inference-http` (LiteLLM readiness, A9 `:8081`/`:8082`/`:8084`/`:8085` `/health`); data-hub
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
