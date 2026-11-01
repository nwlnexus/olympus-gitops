# Spread, disruption budgets and the descheduler (2026-11-01)

Steps 2 and 3 of nwlnexus/olympus-sdk#707. Step 1 (`2026-11-01-requests.md`) gave every workload realistic
requests; these steps make the cluster move pods after placement.

## Step 2: spread constraints and PodDisruptionBudgets

Live Deployments and StatefulSets with `replicas >= 2` on 2026-11-01 (`kubectl get deploy,sts -A`): five
Deployments, no StatefulSets. Each gets one soft constraint
(`maxSkew: 1`, `topologyKey: kubernetes.io/hostname`, `whenUnsatisfiable: ScheduleAnyway`, selector = the pod's
name label). The existing preferred pod anti-affinity stays; the constraint adds a skew the descheduler can
act on. Single-replica workloads get no constraint.

| Namespace | Deployment | Manifest | PDB |
|---|---|---|---|
| cloudflared | cloudflared | `clusters/olympus/cloudflared/deployment.yaml` | **added**: `cloudflared/pdb.yaml`, `maxUnavailable: 1` |
| inference | litellm | `clusters/olympus/inference/litellm.yaml` | existing (`minAvailable: 1`) |
| memory | memory-gateway | `clusters/olympus/memory/gateway/gateway.yaml` | existing (`maxUnavailable: 1`) |
| memory | memory-worker-embed | `clusters/olympus/memory/workers/workers.yaml` | existing (`maxUnavailable: 1`) |
| memory | memory-embedder | `clusters/olympus/memory/embedder/embedder.yaml` | existing (`maxUnavailable: 1`) |

Existing PDBs (`kubectl get pdb -A`): `inference/litellm`, `memory/memory-embedder`, `memory/memory-gateway`,
`memory/memory-worker-embed`, `platform/redpanda` (chart-made, `maxUnavailable: 1`, so it does not block a drain
of the single broker).

**Single-replica stateful workloads (postgres, redpanda, prometheus, loki, tempo): no new PDB.** A
`maxUnavailable: 0` (or `minAvailable: 1` on one replica) budget makes every eviction fail, so
system-upgrade-controller's node drain would hang on that node and k3s upgrades would stall. They are kept
safe from the descheduler instead (exclusions below); a drain still moves them, which is the intended
behaviour for upgrades.

## Step 3: descheduler

`clusters/olympus/descheduler/` (namespace, HelmRepository `https://kubernetes-sigs.github.io/descheduler/`,
HelmRelease chart `0.37.0`, the newest in the index, published 2026-10-04), wired in through
`flux-kustomizations/descheduler.yaml` (same shape as the other apps: `prune`, `wait`, `timeout: 5m`; no
`dependsOn`, as it needs no secrets, certificates or storage).

- `kind: CronJob`, `*/30 * * * *`, `concurrencyPolicy: Forbid` (chart), `activeDeadlineSeconds: 600`,
  3 successful and 3 failed Jobs kept so the last runs' logs can be read.
- Image `registry.k8s.io/descheduler/descheduler:v0.37.0`, pinned by its index digest; the index lists
  linux/amd64, linux/arm and linux/arm64. No node selector: the tainted nodes repel it, so it runs on an
  untainted amd64 node.
- Requests 20m / 64Mi, limits 500m / 256Mi (chart default limits).
- Real mode, not dry run, with bounded evictions: `maxNoOfPodsToEvictPerNode: 3`,
  `maxNoOfPodsToEvictTotal: 10` per run. PDBs are honoured (the descheduler uses the Eviction API).

### Plugins (one profile, `balance`)

- **LowNodeUtilization**: thresholds and reasoning below.
- **RemoveDuplicates**: evicts a second pod of the same owner on one node.
- **RemovePodsViolatingTopologySpreadConstraint** with `constraints: [DoNotSchedule, ScheduleAnyway]`. The
  plugin's default is hard constraints only, and every constraint in this repo is `ScheduleAnyway`, so the
  default would do nothing. Including soft constraints can evict a pod the scheduler then places back on the
  same node (a soft constraint only scores); `nodeFit` (the pod must fit another node), `minPodAge: 1h` and
  the per-run limits bound that churn.

### LowNodeUtilization thresholds

LowNodeUtilization works on **requests** (not live usage): a node is *underutilised* when cpu, memory and
pod count are all below `thresholds`, and *overutilised* when any one is above `targetThresholds`. Pods are a
percentage of the node's pod capacity (110 on every node).

Per-node requested percentages with step 1's requests (live pods on 2026-11-01, each container's request
replaced by its step 1 value, prometheus-server at 2240Mi; all Running pods, DaemonSets included, as the plugin counts them):

| Node | Pods | Pods % | CPU requested | CPU % | Memory requested | Memory % | Class (16/19 pods, 20/50 cpu, 20/50 mem) |
|---|---|---|---|---|---|---|---|
| onode-0312ce | 26 | 23.6 | 1430m of 15 | 9.5 | 7144Mi of 23.2Gi | 30.1 | **over** (pods) |
| onode-0314ac | 22 | 20.0 | 470m of 15 | 3.1 | 1324Mi | 5.6 | **over** (pods) |
| onode-030c31 | 16 | 14.5 | 180m of 15 | 1.2 | 1616Mi | 6.8 | **under** |
| naraka-01 | 7 | 6.4 | 30m of 4 | 0.8 | 160Mi of 121.5Gi | 0.1 | **under** |
| onode-062caa (agent-services, tainted) | 9 | 8.2 | 2090m | 13.9 | 4400Mi of 14.8Gi | 29.0 | between |
| onode-0636e4 (agent-services, tainted) | 9 | 8.2 | 2080m | 13.9 | 3664Mi | 24.2 | between |
| data-hub-vm, mmini-01-vm, mmini-02-vm (arm64, tainted) | 2 each | 1.8 | 0 | 0 | 0 | 0 | under |

(For comparison, before step 1 the busiest node, onode-0312ce, read 9.2% cpu and 14.6% memory.)

Why these values:

- The suggested 20/50 cpu, 20/50 memory and 20/40 pods leave **no node overutilised**: the highest cpu is
  13.9% and the highest memory 30.1%, and no node has 44 pods. The plugin aborts when either set is empty,
  so it would never run.
- With step 1's small requests, the **pod count** is what separates the crowded onodes from the empty ones,
  and it is also what the issue's Done-when measures. Pods `thresholds: 16` (17 or fewer pods) /
  `targetThresholds: 19` (21 or more pods) makes onode-0312ce (26) and onode-0314ac (22) overutilised and
  onode-030c31 (16) and naraka-01 (7) underutilised. The four untainted amd64 nodes hold 71 pods, about 18
  each when balanced, which sits inside the 16-19% band, so a balanced cluster stops evicting instead of
  oscillating.
- cpu and memory keep 20 / 50: no node is near 50%, so they act as a guard for a node that becomes
  genuinely heavy, and the agent-services nodes (29% memory) are neither source nor target.
- `useDeviationThresholds` does not fit: the six almost empty tainted nodes pull the cluster mean down (mean
  pods 9.6%), so onode-030c31 (14.5%) can never be below the mean, and the agent-services nodes (29% memory
  vs a 10.6% mean) would become eviction sources.
- The tainted nodes count as underutilised targets, but `nodeFit` only evicts a pod that fits some other
  node (taints, affinity, resources), so nothing is evicted towards a node it cannot run on. When step 4
  gives workloads the arm64 toleration, those VMs become real targets with no policy change.
- An ephemeral CI runner on onode-030c31 can push it to 17-18 pods (no longer underutilised) for the length
  of a job; the next run picks it up again.

### What the descheduler may not evict

Protections in `DefaultEvictor` (`podProtections`, the v0.37 replacement for the deprecated booleans):

| Protection | Setting | Reason |
|---|---|---|
| Pods with local storage (emptyDir, hostPath) | default protection kept (the old `evictLocalStoragePods: false`) | scratch data is lost on eviction; also keeps traefik, onepassword-connect, the Flux and ARC controllers in place |
| System-critical pods | default protection kept (the old `evictSystemCriticalPods: false`) | coredns, metrics-server, kube-vip, Flux controllers |
| DaemonSet pods, failed bare pods | default protections kept | |
| Pods with a `qnap-iscsi` PVC | `extraEnabled: [PodsWithPVC]`, `protectedStorageClasses: [qnap-iscsi]` | RWO iSCSI: an eviction is a detach/attach and the only consumer is down meanwhile (postgres, redpanda, prometheus-server, loki, tempo, alertmanager, grafana, portainer). Pods with `qnap-nfs` (RWX) PVCs stay evictable. |
| `nodeFit: true` | | never evict a pod that cannot be scheduled elsewhere |
| `minPodAge: 1h` | | do not re-evict a pod a previous run (or a rollout) just placed |

Namespaces excluded wholesale (`namespaceLabelSelector`, `kubernetes.io/metadata.name NotIn`):

| Namespace | Reason |
|---|---|
| kube-system | k3s components (coredns, metrics-server, local-path-provisioner, kube-vip, svclb) |
| flux-system | the GitOps controllers themselves |
| trident | the CSI driver; evicting the controller interrupts volume attach/detach for every pod being moved |
| tailscale | operator-managed proxies (`ts-*` StatefulSets): each move is a tailnet blip for its Service, and the nameserver |
| arc-system | ARC controller and listeners; a listener restart drops queued job assignments |
| arc-runners | ephemeral runners must never be evicted mid-job |
| memory | postgres (stateful singleton) and the single-replica extract worker. Since olympus-sdk#707 the gateway, workers and indexer may run on any node (the arm64 Mac VMs included) and are placed evenly at each rollout by their topology spread (ScheduleAnyway) and anti-affinity; the exclusion is kept (policy unchanged) and is worth revisiting if they drift into skew |
| system-upgrade | the controller that drains nodes for k3s upgrades must not be evicted during one |
| descheduler | itself |

Stateful singletons are also excluded by label (`app.kubernetes.io/name NotIn [postgres, redpanda,
prometheus, loki, tempo]`), so they stay put even if their volume ever moves off `qnap-iscsi`.

Single-replica stateless controllers (cert-manager, external-secrets, external-dns, whoami, ...) are
evictable: a restart of a few seconds is the price of balance, and without that the busy onodes would have
almost nothing movable.

### Validation

- `yamllint -c .yamllint.yaml clusters .github`, and `kustomize build | kubeconform -strict
  -ignore-missing-schemas` (Kubernetes schemas + datree CRDs-catalog) for every touched directory.
- `helm template` of chart 0.37.0 with the HelmRelease values renders the CronJob and the `descheduler`
  ConfigMap with the policy above.
- The rendered policy was loaded by the pinned descheduler v0.37.0 image (strict decoding and validation
  pass; it then stops at the API connection). A deliberately broken copy (pods threshold above target, or an
  unknown field) is rejected at the same step.
