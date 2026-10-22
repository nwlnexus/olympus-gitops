# memory-embedder — in-cluster text embeddings (olympus-sdk#529, epic #444)

A small, boring CPU embedding service in namespace `memory`: HuggingFace
[text-embeddings-inference](https://github.com/huggingface/text-embeddings-inference) (TEI) serving
`nomic-ai/nomic-embed-text-v1.5` (768 dimensions, mean pooling, L2-normalised) behind an OpenAI-compatible
`POST /v1/embeddings`. It replaces Ollama on data-hub for embeddings (Ollama's embedder stalls because of a
scheduler lock bug, olympus-sdk#527), so the capture and recall path no longer depends on the GPU host.

**Nothing consumes it yet.** The workers and the gateway switch to it with olympus-sdk#529 task 2; until then
the Flux Kustomization only deploys and watches it.

| File | What |
|---|---|
| `embedder.yaml` | `PVC/memory-embedder-cache` (2Gi `qnap-nfs`, RWX), `Service/memory-embedder` (80 to 8080), `PodDisruptionBudget`, `Deployment/memory-embedder` (2 replicas, init container `fetch-model` + server) |
| `fetch-model.sh`, `SHA256SUMS` | the init step and the checksums of the pinned model files (ConfigMap `memory-embedder-init`, hash-suffixed so a change rolls the pods) |
| `networkpolicy.yaml` | `allow-embedder-ingress` |
| `kustomization.yaml` | the above |

Deployed by its own Flux Kustomization, `../../flux-kustomizations/memory-embedder.yaml` (`dependsOn: memory`,
health-checks the Deployment, `prune: true`), like the gateway and the workers: a broken embedder rollout can
only make `memory-embedder` unhealthy, never the stores, the gateway or the workers.

## Pins

| What | Value |
|---|---|
| Image | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4` (released 2026-09-15) pinned as `@sha256:2538ea1c9640d3763b15af668039d24172d063b42337b0c27796fc2be180c78d` (the multi-arch index; `linux/amd64` is the only platform in it, the cluster is amd64) |
| Model | `nomic-ai/nomic-embed-text-v1.5` at commit `e5cf08aadaa33385f5990def41f7a23405aec398` (2025-07-21) |
| Model files | 8 files listed with their SHA-256 in `SHA256SUMS`; the init step refuses anything that does not match |
| Backend | ONNX Runtime, picked by TEI because the model directory contains `onnx/model.onnx` (fp32, not quantised) |

**Why not the newest model revision.** `e9b6763` (2026-04-07, "v5 Transformers") rewrote `config.json` with a
duplicate `hidden_size` key. TEI's ONNX config parser rejects it ("duplicate field `hidden_size`") and silently
falls back to the candle backend, which is 1.4 to 2.5 times slower and does not scale with CPUs (measured, see
the PR). The weights are byte-identical in both revisions (same SHA-256), so nothing is lost by pinning the older
one. Re-test before moving to a newer revision.

### Bumping

1. **Image.** Find the tag and its digest:
   ```sh
   TOK=$(curl -s "https://ghcr.io/token?scope=repository:huggingface/text-embeddings-inference:pull" | jq -r .token)
   curl -sI -H "Authorization: Bearer $TOK" \
     -H "Accept: application/vnd.oci.image.index.v1+json" \
     https://ghcr.io/v2/huggingface/text-embeddings-inference/manifests/cpu-<X.Y.Z> | grep -i docker-content-digest
   ```
   Replace the digest in **both** places in `embedder.yaml` (init container and server use the same image) and
   the pin table above. Read the TEI release notes; run the checks under "First-run checks" on a laptop first
   (`podman run` with the same arguments) and compare vectors with the current ones: they must match to cosine
   0.99999 or better.
2. **Model revision.** Pick a commit from `https://huggingface.co/api/models/nomic-ai/nomic-embed-text-v1.5`
   (field `sha`), download the files listed in `SHA256SUMS` from
   `https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/resolve/<sha>/<file>`, regenerate `SHA256SUMS`
   (`sha256sum <files>`, two spaces, relative paths, `onnx/model.onnx` included), and change `MODEL_REVISION`
   (and the header comment) in `embedder.yaml`. See "Rolling the model" for what that does to stored vectors.

## Engine decision

TEI was verified on this exact model first (PR description has the numbers): it supports the NomicBert
architecture, returns 768-dimension vectors, and its cosine similarity to the vectors Ollama's `nomic-embed-text`
returns is at least 0.9999993 for 255 texts (the two are numerically the same model). `llama.cpp` with the same
GGUF Ollama uses was measured too: about 1.3x faster than TEI's ONNX backend per CPU, not chosen because TEI
is a purpose-built embedding server (OpenAI shape, metrics, health that exercises the backend, bounded
queue, a Rust process without the slot logic Ollama is built on). If CPU ever becomes the constraint it is the
fallback.

Behaviours clients should know:

- **Prefixes are the client's job.** The server adds none: send `search_document: ` / `search_query: ` yourself.
- **Output is L2-normalised** (norm 1.0). Ollama's legacy `/api/embeddings` returned unnormalised vectors
  (norm about 20 to 23). Cosine similarity, and therefore the `vector_cosine_ops` HNSW index in
  `fact_embedding`, is unaffected; inner-product or L2 ranking over a mixture of old and new vectors would be.
- **Long inputs are truncated, not rejected.** Anything above 2048 tokens (about 6,000 to 8,000 characters)
  is cut to its first 2048 tokens and answered with 200 (`usage.prompt_tokens` says 2048). Ollama answers
  HTTP 500 "the input length exceeds the context length" above about 7,000 characters.
- **Limits.** 32 inputs per request (422 above), 1 MB body, 128 requests in flight per replica (HTTP 429
  "Model is overloaded" above that: retry with backoff), empty input is 400. `model` is echoed, not used.
  A `dimensions` field is honoured (it truncates), do not send it.
- A client that gives up (timeout, disconnect) does **not** cancel the work already queued for it; the server
  stays healthy and drains it (see the PR for the 20 x cancel test), but impatient clients waste CPU. Keep
  client timeouts well above the queueing delay (30 s or more) and offered load below capacity.

## Model cache and egress

`fetch-model` (init container, same image) keeps the verified model on `PVC/memory-embedder-cache` and copies
it to a pod-local `emptyDir` that the server mounts read-only; the PVC is mounted only by the init container.

- First start: downloads 8 files (about 550 MB) from `huggingface.co` (the large file is served by
  `*.hf.co`, today `us.aws.cdn.hf.co`), checks every SHA-256, and publishes the directory with one atomic
  rename. Both replicas starting together both download; one wins the rename, the other discards its copy and
  uses the winner's (tested: 24 s for both on an empty cache).
- Later starts: sha256 check of the cache and the copy, no network (about 4 s).
- A cache entry that fails verification is discarded and downloaded again.
- Bounded and visible: each file has 15 s connect / 420 s total timeouts and 6 retries 5 s apart, the whole
  step has a 900 s hard deadline, and it logs one line per file. A failure leaves the pod in `Init:Error` /
  `Init:CrashLoopBackOff` with the reason in `kubectl -n memory logs <pod> -c fetch-model`; the kubelet retries
  with back-off, and `MemoryEmbedderDown` fires after 10 minutes without a ready replica.
- **Egress**: only the init container needs the internet, once per cache population: `huggingface.co:443` and
  `*.hf.co:443`. Verified read-only that no NetworkPolicy in `memory` has `policyTypes: Egress` (the only egress
  policies in the cluster are in `arc-runners`, `arc-system`, `flux-system` and `kvm-device-plugin`), and that
  `huggingface.co` and `us.aws.cdn.hf.co` are reachable from a node. Not verified: a pod-level download (no
  cluster writes from the build session); the first deploy is that test.
- `qnap-nfs` has `reclaimPolicy: Delete`, `archiveOnDelete: false`. That is acceptable for a rebuildable cache,
  so the PVC is pruned with the rest on rollback (unlike `memory-backups`, which carries `prune: disabled`).

The server container itself needs no write access outside `/tmp` (64Mi `emptyDir`, TEI's internal socket) and
the read-only `/model`; Pod Security `restricted` (non-root uid 10001, read-only root filesystem, all
capabilities dropped, seccomp `RuntimeDefault`, no ServiceAccount token).

## Network

Ingress to port 8080 (default-deny namespace) from: the gateway (`memory-gateway`), the embed and extract
workers (`memory-worker-embed`, `memory-worker-extract`), the blackbox-exporter (the `/health` probe) and the
Prometheus server (`/metrics`, via the pod annotations). Nothing else, not even the databases.

## Sizing

Measured with `podman --cpus N` on an Intel Core Ultra 7 255H (16 cores, AVX2), the same image and model
revision, ONNX backend. Throughput is flat in the number of concurrent clients (the server is saturated by one)
and linear in CPUs:

| CPUs | 100-char facts (29 tokens) | 220-char facts (68 tokens) | 520-char passages (163 tokens) |
|---|---|---|---|
| 2 | 15.1 /s | 7.3 /s | 3.0 /s |
| 4 | 28.5 /s | 13.9 /s | 6.1 /s |
| 6 | 38.9 /s | 19.3 /s | 8.8 /s |
| 8 | 50.0 /s | 25.2 /s | 11.3 /s |

That is about 200 tokens/s per CPU. Memory: 1.5 GB idle, 2.1 GB peak under the worst test load (8 x 8,000
character documents in a batch, 128 queued). Start: 4 s (model warm-up) after the init step.

Derived: 20 embeddings/s of 220-character facts is about 6 CPUs of work (about 3 CPUs for 100-character
facts), so **2 replicas x (request 2 CPU, limit 6 CPU), 2 GiB request / 3 GiB limit** run at about half load
at 20/s and keep serving through the loss of one replica (one replica alone sustains 19 /s of 220-character
facts, 39 /s of 100-character ones). Replicas are spread over the onodes; they are also the k3s control plane,
which is why the limit is 6 and not "unlimited". The nodes' CPUs are AMD Ryzen 7 6800H, not the CPU used for the
measurements: after the first deploy, repeat the load check below and scale if it is lower than expected
(`resources.limits.cpu` and the three thread variables together, or `replicas`).

Load check after deploy (from a toolbox pod or `kubectl port-forward`; do not run it against production data):

```sh
kubectl -n memory port-forward svc/memory-embedder 8080:80 &
# 100 sequential requests for a short fact: expect a median of a few tens of ms (35 ms measured with 4 CPUs)
for i in $(seq 100); do curl -s -o /dev/null -w '%{time_total}\n' localhost:8080/v1/embeddings \
  -H 'content-type: application/json' -d '{"input":"search_document: Ollama on data-hub listens on 0.0.0.0:11434."}'; done | sort -n | sed -n '50p;95p'
```

## First-run checks

```sh
flux get kustomization memory-embedder
kubectl -n memory get pods -l app.kubernetes.io/name=memory-embedder -o wide   # 2 pods, Running 1/1, on two different onodes
kubectl -n memory logs deploy/memory-embedder -c fetch-model                    # "model ready in /model (523M)"
kubectl -n memory logs deploy/memory-embedder -c embedder | grep -E 'Ready|ort|Warming'
kubectl -n memory get pvc memory-embedder-cache                                # Bound
kubectl -n memory port-forward svc/memory-embedder 8080:80 &
curl -s localhost:8080/info | jq '{model_id, served_model_name, max_input_length, version}'
curl -s localhost:8080/v1/embeddings -H 'content-type: application/json' \
  -d '{"input":["search_query: hello"],"model":"nomic-embed-text-v1.5"}' | jq '.data[0].embedding | length'   # 768
curl -s localhost:8080/metrics | grep -c '^te_'                                 # metrics present
```

In Prometheus: `up{job="kubernetes-pods",app_kubernetes_io_name="memory-embedder"}` is 1 for
both pods, `probe_success{job="blackbox-memory-embedder"}` is 1, and the alerts `MemoryEmbedder*` are inactive.
A stalled embedder is caught three ways: the probe (`MemoryEmbedderDown`, 10 m), the pods' own series
(`MemoryEmbedderMetricsAbsent`, `MemoryEmbedderDegraded`) and the request series (`MemoryEmbedderErrorRate`,
`MemoryEmbedderSlow`). Rules and their `promtool` tests: `../../observability/prometheus-helmrelease.yaml`,
`../../observability/tests/memory-embedder-alerts.test.yaml`.

## Rolling the model

A new image digest or model revision rolls the Deployment (`maxUnavailable: 0`, `maxSurge: 1`: a third pod
starts, becomes ready, then an old one goes). The cache directory is named after repo and revision, so the old
and the new revision coexist on the PVC (2Gi holds both); delete the old directory by hand when you are done.

**A different model revision or model is a different embedding space.** Vectors computed by the old and the new
one must not be mixed in `memory.fact_embedding`. For a revision bump with identical weights (as the pin above
vs the newest revision) the vectors are identical and nothing needs to change; for different weights, re-embed
every row (olympus-sdk#529 task 3) and record the model per row before pointing recall at the new vectors.

## Roll back / disable

Remove `  - flux-kustomizations/memory-embedder.yaml` from `../../kustomization.yaml`; `prune: true` deletes the
Deployment, Service, PDB, NetworkPolicy, ConfigMap and the cache PVC. Nothing depends on the embedder yet, so this
is safe at any point before the consumers are switched (after that, switch them back to LiteLLM first). Alerts and
the blackbox job stay in the Prometheus HelmRelease; remove the `blackbox-memory-embedder` job and the
`MemoryEmbedder*` rules in the same commit when the service is retired, or `MemoryEmbedderDown` and
`MemoryEmbedderMetricsAbsent` will page.
