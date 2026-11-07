# arc: CI runners on the cluster

GitHub's runner scale set controller (ARC) running ephemeral CI runner pods on
compute-hub. Design: `docs/superpowers/specs/2026-10-19-ci-runners-on-cluster-design.md`
in `nwlnexus/olympus-sdk`; epic `nwlnexus/olympus-sdk#383` (this directory implements #386, #387
and, with `../kvm-device-plugin/`, #390).

**Status: live.** `olympus-linux` runs with `maxRunners: 3` and `olympus-gate` with
`maxRunners: 8` (since 2026-10-19, after the preconditions below). `olympus-kvm`
(`maxRunners: 2`) runs nothing until a node carries the KVM label (KVM section).

## Layout

| File | Purpose |
|------|---------|
| `namespace.yaml` | `arc-system` (controller + listeners), `arc-runners` (runner pods of all scale sets, PSA `restricted`) |
| `priorityclass.yaml` | `ci-runner` and `ci-runner-kvm`, both value -1000, `preemptionPolicy: Never` (below every other workload); two classes only so the quota can scope the KVM budget |
| `quota.yaml`, `limitrange.yaml` | hard ceilings: total 14 pods; `ci-runners-non-kvm` (olympus-linux + olympus-gate: 12 pods, 8.5 CPU / 17 GiB requests, 20 CPU / 36 GiB limits, no `/dev/kvm`) and `ci-runners-kvm` (2 pods, 4 CPU / 8 GiB requests, 6 CPU / 16 GiB limits, 2 `olympus.io/kvm`); default requests/limits for every container |
| `networkpolicy.yaml` | default-deny ingress; runner egress = DNS + public internet only (no IPv4 cluster, node, LAN or tailnet addresses), plus `egress-litellm-kvm`: pods labelled `olympus.io/ci-kvm` (olympus-kvm only) may reach the `inference` LiteLLM pods on TCP 4000 (executor, olympus-sdk#642), plus `egress-ci-egress-proxy`: every runner pod may reach the egress proxy pods in `ci-egress` on TCP 3128 (olympus-sdk#407); controller/listener egress adds the API server only |
| `../ci-egress/` | separate Flux app: the CI egress forward proxy (squid, 2 replicas), see "Egress proxy" below |
| `networkpolicy-metrics.yaml` | additive: only the Prometheus server (ns `observability`) may reach the controller and listener pods in `arc-system` on TCP 8080 (metrics, olympus-sdk#392) |
| `externalsecret.yaml` | `arc-github-app` Secret (GitHub App credentials) from 1Password via ESO |
| `ocirepository.yaml` | both charts pinned by digest (`ghcr.io/actions/actions-runner-controller-charts`) |
| `helmrelease-controller.yaml` | `gha-runner-scale-set-controller` (release `arc`, CRDs `CreateReplace`, `watchSingleNamespace: arc-runners`, image pinned by digest) |
| `helmrelease-scale-set.yaml` | `gha-runner-scale-set` release `olympus-linux` (`runs-on: olympus-linux`), no container mode |
| `helmrelease-scale-set-gate.yaml` | scale set `olympus-gate` (`runs-on: olympus-gate`), tiny pods for the CI gate poller |
| `helmrelease-scale-set-arm64.yaml` | scale set `olympus-arm64` (`runs-on: olympus-arm64`), runners on the arm64 Linux VMs of the Mac minis (olympus-sdk#694, H20); see the arm64 section |
| `helmrelease-scale-set-kvm.yaml` | scale set `olympus-kvm` (`runs-on: olympus-kvm`), the QEMU VM suites, `/dev/kvm` via the device plugin |
| `../kvm-device-plugin/` | separate Flux app: `generic-device-plugin` DaemonSet (our mirror, digest-pinned) advertising `/dev/kvm` as `olympus.io/kvm` on nodes labelled `node-restriction.kubernetes.io/kvm-ci=true`; its PriorityClass `ci-device-plugin` and a ValidatingAdmissionPolicy pinning the image (the one PSA `privileged` namespace; see KVM below) |

## Scale sets

All in `arc-runners`, same chart pin, same GitHub App Secret and runner group `olympus-ci`,
same hardening (restricted, uid 1001, no SA token, no service links, priority -1000, our runner
image by digest, `activeDeadlineSeconds` so a stuck job cannot hold a slot for days).

| Scale set | For | Pods | Per pod (requests / limits) |
|-----------|-----|------|------------------------------|
| `olympus-linux` | CI jobs (lint, test, build) | max 3 (`maxRunners`; quota room for 4) | 2 CPU, 4 GiB / 4 CPU, 8 GiB; spread over the onodes via label `olympus.io/ci-runner`; deadline 3 h |
| `olympus-gate` | the CI gate workflow: a poller (bash, gh, jq) that waits up to 120 min for sibling workflows | max 8 | 50m, 128Mi, 256Mi ephemeral / 500m, 512Mi, 2Gi; label `olympus.io/ci-gate`, soft spread (maxSkew 2, ScheduleAnyway); deadline 150 min |
| `olympus-arm64` | arm64 jobs on the Mac-mini VMs (nothing routes there yet; `arm64-runner-smoke.yml` is the first user) | max 2, one per VM | 2 CPU, 4 GiB, 4 GiB ephemeral / 4 CPU, 7 GiB, 15 GiB; label `olympus.io/ci-runner-arm64`, deadline 3 h |
| `olympus-kvm` | VM suites (`vm-tests.yml`, `make vm-test`) | max 2 | 2 CPU, 4 GiB, 4 GiB ephemeral, `olympus.io/kvm: 1` / 3 CPU, 8 GiB, 15 GiB; label `olympus.io/ci-kvm`, only on nodes labelled `node-restriction.kubernetes.io/kvm-ci=true`, supplemental group 994 (`kvm`); KVM image variant by digest; deadline 2 h |

The gate has its own pool on purpose: if it shared the 3 `olympus-linux` slots, three open
PRs would each hold a slot while waiting for jobs that can never be scheduled (deadlock).
The `arc-runners` quota is split by priority class: `ci-runners-non-kvm` (12 pods, requests
8.5 CPU / 17 GiB, limits 20 CPU / 36 GiB) is the runner budget plus the gate budget, unchanged by
#390; `ci-runners-kvm` is two KVM pods; `ci-runners` is the sum (14 pods, and the only place
ephemeral storage is capped: scoped quotas cannot carry it). NetworkPolicies and the LimitRange select/apply to the
whole namespace, so gate pods get the same isolation. The controller (`watchSingleNamespace:
arc-runners`) serves any number of scale sets in that namespace; each adds one listener pod
in `arc-system` (quota 10 pods: the controller and 3 listeners today).

Charts are `0.15.0` (controller and scale set must always be bumped together; update
tag and digest of both OCIRepository objects). `watchSingleNamespace` removes the
cluster-wide ClusterRole; the consequence is that scale sets must live in
`arc-runners` (all three do; the former `arc-runners-kvm` placeholder namespace was
removed in #390 because KVM needs no PSA exception).

## arm64: `olympus-arm64` (olympus-sdk#694, decision H20)

The Mac minis each run one Linux arm64 VM as a k3s agent labelled `olympus.io/host=mac-mini` and
tainted `olympus.io/arch=arm64:NoSchedule` (6 vCPU / 12 GiB, kubelet reserves as on the onodes); data-hub
runs a third, `olympus.io/host=mac-studio` (8 vCPU / 32 GiB, olympus-sdk#701). The taint keeps
everything off that does not opt in; since olympus-sdk#707 the stateless services whose images are all
multi-arch tolerate it too (their requests total well under one runner's headroom per VM, so a runner
still fits). `olympus-arm64` is a copy of `olympus-linux` with: `nodeSelector`
`kubernetes.io/arch: arm64` (every Mac VM; they are the only arm64 nodes), a toleration for the taint, `maxRunners: 3`
with a hard hostname spread (one runner per VM), and a 4 CPU / 7 GiB limit that fits the VM after the
reserves. Same runner group `olympus-ci`, same hardening and the same image **name** as `olympus-linux`;
the runner tag is a multi-arch manifest list (olympus-sdk `ci/runner/README.md`), pinned by its index digest.

- **Listener and controller stay on amd64.** The listener pod is created from `listenerTemplate`, not the
  runner template, so it never gets the toleration; `listenerTemplate` also sets `kubernetes.io/arch: amd64`.
  The controller has no toleration either. Both images are multi-arch anyway.
- **Image pin.** `helmrelease-scale-set-arm64.yaml` pins the multi-arch **index** digest from olympus-sdk's
  runner-image run 41216712374 (linux/amd64 + linux/arm64); the kubelet picks the arm64 entry. The amd64 sets
  (`olympus-linux`, `olympus-gate`) stay on their single-arch pin until they are moved deliberately: the
  index's amd64 image has a newer Ubuntu base, so moving them is its own change.
- **Quota.** `arc-runners` quotas were raised for 2 pods (see `quota.yaml`); the pool is shared with
  `olympus-linux`.
- **Rollout order.** (1) olympus-sdk PR merged, image pushed; (2) digest bumped here; (3) VMs joined to k3s;
  (4) dispatch `arm64-runner-smoke.yml`. Merging before the VMs exist is harmless: the set has no nodes to
  schedule on and no workflow requests it.

## KVM: `olympus-kvm` and the device plugin (olympus-sdk#390)

The VM suites (`vms/harness/vm.sh`, `make vm-test`) boot throwaway Ubuntu cloud images
with QEMU and need `/dev/kvm`. They run in an **unprivileged** runner pod under PSA
`restricted`:

1. `../kvm-device-plugin/` runs `generic-device-plugin` as a DaemonSet on nodes labelled
   `node-restriction.kubernetes.io/kvm-ci=true`. It advertises the host's `/dev/kvm` as
   the extended resource `olympus.io/kvm` with `count: 1` (one holder per node). That
   namespace is the only PSA `privileged` one, because the plugin needs two hostPath
   mounts: the kubelet's `/var/lib/kubelet/device-plugins` socket directory and the
   `/dev/kvm` node (which it only stats to discover the device). The plugin container
   is not a privileged container (uid 0 with all capabilities dropped, no privilege
   escalation, read-only root fs, no SA token, default-deny network policy), **but it
   must be trusted like root on that node**: it answers the kubelet's Allocate calls,
   so a malicious plugin image could inject any host device or host path into the KVM
   runner pod, and as uid 0 it can write `kubelet.sock` and
   `kubelet_internal_checkpoint` in the device-plugins directory (verified by the
   security review in a throwaway namespace). Mitigations: the image is our own mirror,
   pinned by digest; a ValidatingAdmissionPolicy (`vap.yaml`) admits only that image,
   and no init or ephemeral containers, in the namespace; it runs only on labelled
   nodes; PriorityClass `ci-device-plugin` (1000, never preempts) keeps it from being
   evicted before ordinary workloads without outranking platform components.
2. A runner pod that requests `olympus.io/kvm: 1` gets exactly one extra device node,
   `/dev/kvm`, created by the runtime with the HOST owner and mode (`root:994 0660`).
   `securityContext.supplementalGroups: [994]` (the host `kvm` group) lets uid 1001 open
   it. No capabilities, no hostPath, seccomp RuntimeDefault, no new privileges.
3. Caps: `maxRunners: 2`, quota `ci-runners-kvm` (2 pods, 2 devices), plugin `count: 1`
   per node; requests 2 CPU / 4 GiB, limits 3 CPU / 8 GiB / 15 GiB ephemeral (3 CPU keeps
   CI at or below half of an onode's 16 cores next to an `olympus-linux` runner and
   gates, spec section 5); `activeDeadlineSeconds: 7200`. The VM
   (default `VM_CPUS=2`, `VM_MEM=2048`) runs inside the pod, so QEMU's guest RAM counts
   against the pod's memory limit.
4. Network: the arc-runners policy applies unchanged. QEMU user-mode networking runs in
   the pod's network namespace (guest SSH and the cloud-init HTTP server are on
   127.0.0.1 in the pod); the cloud image download (HTTPS, about 825 MB) and the guest's
   DNS go through the pod's normal egress. Nothing needs host networking.
5. Cache: the cloud image is cached in `~/.cache/olympus-vm` on the pod's root fs and
   restored by `actions/cache` in the workflow (a restored image is still verified
   against Ubuntu's SHA256SUMS over HTTPS by `vm.sh image` and re-downloaded on
   mismatch, so a poisoned cache entry cannot reach a VM); VM disks are qcow2 overlays under the
   work dir, deleted after each suite. Both count against the 15 GiB ephemeral limit.
   No node-level cache volume, so nothing written by one job is visible to the next.

### Prerequisites before labelling a node (owner, olympus-infra; not in this repo)

1. Image mirror `ghcr.io/nwlnexus/generic-device-plugin` must be **public** (anonymous
   pull), or the plugin pod cannot start (ImagePullBackOff; nothing else breaks).
2. kubelet `pod-max-pids` on all onodes (k3s `kubelet-arg`), so a fork bomb in any CI
   pod, KVM or not, cannot exhaust the node's PIDs.
3. `kvm_intel nested=0` (or `kvm_amd nested=0`) on the KVM node: no nested
   virtualisation inside CI guests, a smaller hypervisor attack surface.
4. A kernel patch and reboot cadence for the KVM node (KVM is kernel code reachable
   from the runner pod through `/dev/kvm` ioctls; follow Ubuntu USNs for `linux`).
5. Accept the residual risk stated plainly: the KVM node (onode-030c31) is a k3s
   server and **etcd member**. A guest-to-host or container escape through a KVM bug
   on that node yields a control-plane node, i.e. the cluster and every Secret in it.
   Quota, limits, priority and the network policy do not mitigate this; only kernel
   hygiene, `nested=0` and, longer term, a dedicated non-control-plane KVM node do.

### Node label (manual step)

The label is not managed by Flux (k3s nodes are not in this repo). It uses the
`node-restriction.kubernetes.io/` prefix on purpose: the NodeRestriction admission
plugin (enabled in k3s) forbids a kubelet from setting labels with that prefix on its
own Node, so a compromised node cannot label itself to attract KVM jobs (or the
plugin). Only a cluster admin can set it. On the control plane:

```sh
kubectl label node onode-030c31 node-restriction.kubernetes.io/kvm-ci=true
kubectl get node onode-030c31 -o jsonpath='{.status.allocatable.olympus\.io/kvm}'   # -> 1
```

`onode-030c31` was chosen because it carried the least pod memory (requests 369Mi on
2026-10-19). Until a node is labelled, the DaemonSet has 0 pods and `olympus-kvm` jobs
stay pending (the listener scales, the runner pod is Pending with
`Insufficient olympus.io/kvm`).

### Adding a second KVM node

Done 2026-10-28 (olympus-sdk#460): the second KVM node is `onode-0312ce` (gid 994 and
`/dev/kvm` verified; `nested=0` via olympus-infra `host_vars`). Live label:
`kubectl label node onode-0312ce node-restriction.kubernetes.io/kvm-ci=true`. The steps
below are the general procedure.

1. On the node: `getent group kvm` must print gid **994** (the scale set hard-codes
   `supplementalGroups: [994]`; all three onodes have 994 today). If it differs, the
   pod sees `/dev/kvm` but cannot open it (`vm.sh doctor` prints `accel   tcg`).
2. Do the prerequisites above for that node (`nested=0`, patch cadence, `pod-max-pids`),
   then `kubectl label node <node> node-restriction.kubernetes.io/kvm-ci=true`; check
   `allocatable` as above.
3. PR: raise `maxRunners` to 2 and `ci-runners-kvm` / `ci-runners` by one KVM pod each
   (pods, 2 / 3 CPU, 4 / 8 GiB, `requests.olympus.io/kvm`, and ephemeral in `ci-runners`).
   Prefer a non-control-plane node if one ever exists (see residual risk above).
4. Never label naraka-01 or an agent-services onode: runners belong to the compute
   pool (onode-030c31/0312ce/0314ac, olympus-sdk#567). Every runner set's affinity
   requires `olympus.io/role DoesNotExist` and `kubernetes.io/hostname NotIn [naraka-01]`.

### Evidence (2026-10-19, throwaway namespaces on onode-030c31, since deleted)

Measured with the first version of the manifests (CPU limit 4, upstream image tag of
the same digest, label `olympus.io/kvm-ci`); the follow-up changes (CPU limit 3, mirror,
label prefix, deadlines) were validated by render, server dry-run and PSA check only.
The plugin DaemonSet from `../kvm-device-plugin/` (hardened as committed) registered
`olympus.io/kvm: 1` on the node. A pod with this scale set's exact pod spec and the KVM
image, in a namespace enforcing `restricted` with the arc-runners network policy copied:
`id` -> `uid=1001 groups=1001,994`; `/dev` holds only the default devices plus
`kvm` (`crw-rw---- 0 994 10,232`); `CapEff 0`, `NoNewPrivs 1`, `Seccomp 2`;
`test -r /dev/kvm -a -w /dev/kvm` OK; QEMU monitor `info kvm` -> `kvm support: enabled`;
`vm.sh doctor` -> `accel   kvm`; `make vm-test SUITES=update` PASS (suite 29 s, 70 s with
the image download). Full `make vm-test` (all 9 suites, one VM at a time): **all PASS in
556 s** including a 48 s cloud-image download (hosted runners: about 11 min). During the
run: pod CPU peak 1.4 cores (avg 0.5), QEMU RSS peak 1.07 GiB, pod cgroup memory peak
2.0 GiB (incl. page cache) of the 8 GiB limit, work dir peak 85 MB plus the 826 MB image
cache. etcd on that node: 4931 WAL fsyncs, mean 1.6 ms, 99.8 % under 8 ms, none over
32 ms (same distribution as before the run), while an `olympus-linux` CI job ran on the
same node. The 8 GiB limit therefore leaves room for `VM_MEM` up to about 6 GiB; the
memory request (4 GiB) could drop to 3 GiB after a few weeks of real jobs. The 3-CPU
limit is about twice the measured 1.4-core peak.

## Secret

ESO cannot read 1Password file attachments and text fields flatten PEM newlines, so
the private key is stored base64 on one line (`base64 -w0 key.pem`) in the concealed
field `private-key-b64` of item `arc-github-app` (vault Dev; the field exists and
decodes to the original PEM). `decodingStrategy: Base64` restores the multi-line PEM
in Secret key `github_app_private_key`. `app-id` and `installation-id` are plain fields.

GitHub App blast radius: it has `organization_self_hosted_runners: write` on all
repositories of the org. Its private key is readable via ESO in `arc-runners` (Secret
`arc-github-app`, not mounted into runner pods but in their namespace) and the
controller's copy in `arc-system`. Anyone able to read Secrets in those namespaces can
register runners org-wide. Keep RBAC on both namespaces tight.

## Preconditions before raising maxRunners (ALL DONE 2026-10-19, kept for the record and for rebuilds)

Review of PR #116 found isolation gaps that NetworkPolicy cannot close. None of the
following is in this repo; all must be done (and the probes re-run) before `maxRunners > 0`:

1. **IPv6 link-local.** Every pod and the node's `cni0` carry `fe80::` addresses and
   kube-router programs only IPv4, so a runner pod can reach node sshd, kubelet,
   apiserver, node-exporter, rpcbind and same-node pods over IPv6 link-local with no
   NetworkPolicy involved. Fix: `ip6tables` DROP on `cni0` INPUT and FORWARD on every
   node (olympus-infra).
2. **sshd hardening** on the nodes (password authentication off).
3. **Kubelet reserves** (olympus-infra k3s config), so CI cannot starve the system or etcd:
   `kubelet-arg: system-reserved=cpu=1,memory=2Gi`, `kube-reserved=memory=1Gi`,
   `eviction-hard=memory.available<1Gi,nodefs.available<10%,imagefs.available<10%`.
4. **UniFi gateway.** The gateway's management UI is reachable from pods through its
   WAN IP (dynamic, so no NetworkPolicy exception is possible). Add a UniFi firewall
   rule dropping traffic from node IPs 192.168.253.7, .8, .9 and .14 to the gateway's
   own addresses on 22/80/443/8443.

Re-run after those are in place, from a pod with the runner profile (see the PR
description for the full test pod). Discover the node address with
`ip -6 addr show cni0` on the node (`fe80::...`), then from the pod:

```sh
for p in 22 6443 10250 9100; do curl -g -sS -m 5 -k "https://[fe80::<node-cni0-addr>%eth0]:$p" ; done   # expect all to FAIL
curl -sS -m 5 -k https://68.134.149.230:443                    # gateway WAN IP (replace with the current one): expect FAIL
```

## Known issues of chart 0.15.0 (kept deliberately)

- actions-runner-controller#4715: jobs queued while `maxRunners` was 0 can stay stuck
  after raising it again until a new dispatch or a listener restart
  (`kubectl -n arc-system delete pod -l actions.github.com/scale-set-name=olympus-linux`).
  This hits the drain procedure.
- #4704: about 50 s delay before a replacement runner starts.
- #4712 / #4718: non-quota 403s mark runners Failed and hold the slot until deleted
  (`kubectl -n arc-runners delete ephemeralrunner <name>`).

## Monitoring (olympus-sdk#392)

- **Metrics.** `helmrelease-controller.yaml` sets `metrics:` (chart 0.15.0: `controllerManagerAddr`,
  `listenerAddr`, `listenerEndpoint`); the controller and every listener serve on :8080, port `metrics`.
  Prometheus scrapes them with the static jobs `arc-controller` and `arc-listeners`
  (`../observability/prometheus-helmrelease.yaml`; listener targets carry `scale_set`), allowed by
  `networkpolicy-metrics.yaml`. Listener series: `gha_registered/busy/idle/min/max/desired_runners`,
  `gha_assigned/running_jobs` (label `name` = scale set), `gha_started/completed_jobs_total`,
  `gha_job_startup_duration_seconds` (queue time) and `gha_job_execution_duration_seconds`. Controller:
  `gha_controller_{pending,running,failed}_ephemeral_runners` and `gha_controller_running_listeners`.
- **Dashboard.** Grafana "CI runners" (uid `arc-runners`, `../observability/dashboards/arc-runners.json`):
  runners and jobs per scale set, queue time, job duration, ephemeral runner phases, quota use, and node
  CPU/memory/root disk plus apiserver-side etcd latency while CI runs.
- **Alerts** (group `arc-ci-runners`): `ArcControllerDown`, `ArcListenerDown` (critical);
  `ArcJobsStuckInQueue`, `ArcJobQueueTimeHigh`, `ArcEphemeralRunnersFailed`, `ArcRunnerPodPending`,
  `ArcQuotaSaturated`, `ArcScaleSetDrained`. Group `cluster-nodes`: `KubeNodePressure`, `ClusterNodeRootDiskLow` (critical,
  under 12% free on `/`: etcd, containerd and the runner emptyDirs share that disk on the onodes),
  `ClusterNodeRootDiskFillingUp`, `EtcdRequestLatencyHigh`. Unit tests:
  `../observability/tests/arc-alerts.test.yaml`.
- **macOS runners** (data-hub, mmini-01, mmini-02; not ARC). Each Mac's root LaunchDaemon
  `io.olympus.ci-runner-heartbeat` (nix-darwin-hm `d.server.ciRunner.heartbeat`) pushes gauges every 60 s over
  OTLP/HTTP to `obs-otlp:4318` (`../otel-collector/otlp-tailscale-service.yaml`); the collector's `metrics/agents`
  pipeline remote-writes them here as `{job="ci-runner", host_name="<host>"}`: `ci_runner_daemon_up` (the loop
  daemon runs), `ci_runner_runner_up` (a registered runner is up, idle or busy),
  `ci_runner_last_registration_timestamp_seconds` and `ci_runner_last_wipe_ok`. Alerts (group `ci-runners-macos`,
  all warning): `MacCIRunnerHeartbeatMissing` (a host seen in the last 7 days pushed nothing for about 15 min),
  `MacCIRunnerDaemonDown` (10 min), `MacCIRunnerWipeFailing` (15 min; the loop fails closed and takes no jobs),
  `MacCIRunnerNotRegistered` (loop up, wipe fine, no runner for 30 min: credentials, GitHub API or pf). Hosts that
  never reported raise nothing. No alert on registration age: a JIT runner re-registers only after a job, so an idle
  host keeps one registration for days. Dashboard row "macOS runners"; unit tests
  `../observability/tests/macos-runner-alerts.test.yaml`. The minis are `tag:mac-server`, which has no source grant
  in the tailnet policy, so they cannot reach `obs-otlp` until the owner adds a narrow grant (see "Later").
- **etcd.** k3s serves etcd's own metrics (`etcd_disk_wal_fsync_duration_seconds`) on
  `127.0.0.1:2381` only, so they are not scraped; `EtcdRequestLatencyHigh` uses the apiservers'
  `etcd_request_duration_seconds` instead (non-list p99, 7-day peak under 0.1 s on 2026-11-07, alert at
  0.5 s). Scraping etcd directly needs `etcd-expose-metrics: true` in the k3s config (olympus-infra).

## Runbook

### Drain a scale set (no new runners; running jobs finish)

Durable (Git): set `maxRunners: 0` in that set's `helmrelease-scale-set*.yaml`, merge. Queued jobs wait
on GitHub. The listener does not even acquire them (`gha_assigned_jobs` stays 0), so no queue alert
fires; `ArcScaleSetDrained` reminds after 2 h. Fall back to hosted runners (below) if the drain will last.

Immediate (kubectl, minutes, then follow up in Git or restore): suspend the HelmRelease so helm-controller
does not fight the patch, then patch the AutoscalingRunnerSet. Tested on `olympus-arm64` 2026-11-07
(evidence in olympus-sdk#392):

```sh
kubectl -n arc-runners patch helmrelease olympus-arm64 --type merge -p '{"spec":{"suspend":true}}'
kubectl -n arc-runners patch autoscalingrunnerset olympus-arm64 --type merge -p '{"spec":{"maxRunners":0}}'
kubectl -n arc-runners get autoscalingrunnerset olympus-arm64
```

The controller recreates the listener with the new maximum within seconds (`gha_max_runners{name="olympus-arm64"}`
reads 0, listener log `max=0`); a job dispatched now stays `queued` on GitHub and no EphemeralRunner or pod
is created (2026-11-07: `arm64-runner-smoke` queued for 3 min, `assigned job=0 decision=0`). Restore:

```sh
kubectl -n arc-runners patch autoscalingrunnerset olympus-arm64 --type merge -p '{"spec":{"maxRunners":3}}'
kubectl -n arc-runners patch helmrelease olympus-arm64 --type merge -p '{"spec":{"suspend":false}}'
```

Use the value from Git for `maxRunners`. In the test the queued job got a runner 6 s after the restore (a
fresh listener acquires waiting jobs on start). If a job queued during the drain does not start within a minute
(known issue #4715), restart the listener:
`kubectl -n arc-system delete pod -l actions.github.com/scale-set-name=<set>`.

### Fall back to hosted runners

The workflows read their runner from repository variables (JSON: a quoted label or a label array). In
each repository that uses the pool (`gh variable list -R nwlnexus/<repo>`):

```sh
gh variable set RUNNER_LINUX -R nwlnexus/olympus-sdk --body '"ubuntu-latest"'
gh variable set RUNNER_GATE -R nwlnexus/olympus-sdk --body '"ubuntu-latest"'
gh variable set RUNNER_BROWSER -R nwlnexus/olympus-sdk --body '"ubuntu-latest"'
gh variable delete VM_TEST_RUNNER -R nwlnexus/olympus-sdk
```

Deleting `VM_TEST_RUNNER` sends the VM suites to `ubuntu-latest` (the workflow re-enables KVM with udev
there). `RUNNER_ARM64` unset means `olympus-arm64`; set it to `'"ubuntu-24.04-arm"'` for hosted arm64.
Undo by setting the variables back to `'"olympus-linux"'`, `'"olympus-gate"'`, `'"olympus-kvm"'`.

### Controller and CRD upgrade

1. Read the release notes between the versions (CRD changes, known issues above).
2. One PR: bump tag **and** digest of **both** OCIRepository objects (`ocirepository.yaml`; `helm pull`
   prints the digest) and the controller image tag+digest in `helmrelease-controller.yaml`. Controller
   and scale-set charts must always match.
3. CRDs: the controller HelmRelease uses `crds: CreateReplace`, so Flux replaces them on upgrade. If a
   release requires removing the scale sets first, drain all sets and use the two-step removal below,
   then re-add.
4. After merge: `kubectl -n arc-system get pods` (controller and one listener per set Running), the
   "CI runners" dashboard shows every set registered, then dispatch `arm64-runner-smoke.yml` (olympus-sdk)
   as a canary before the busy sets see traffic.

### Runner image rebuild

See "Runner image" below: build with `ci/runner/build.sh` (olympus-sdk), replace the digest in the scale
set file(s), one PR, never a tag. The arm64 set pins the multi-arch index digest; KVM has its own
variant.

### macOS runners (data-hub, mmini-01, mmini-02; not ARC)

Native JIT runners from nix-darwin-hm `d.server.ciRunner`: LaunchDaemon `io.olympus.ci-runner`, log
`/var/log/ci-runner.log`, one job at a time as `_ghrunner`. Restart on the host (LAN sshd, as an admin):

```sh
sudo launchctl kickstart -k system/io.olympus.ci-runner
sudo launchctl print system/io.olympus.ci-runner
sudo tail -n 50 /var/log/ci-runner.log
```

`kickstart -k` sends TERM: the loop kills the current job's runner and wipes the work dir, so the job
fails as "runner lost". A healthy idle host shows an online runner named `<host>-<timestamp>` in the org
runners list (`gh api orgs/nwlnexus/actions/runners --jq '.runners[] | [.name,.status,.busy] | @tsv'`,
needs an admin token). Alerts (`MacCIRunner*`, Monitoring above): for a missing heartbeat check the host is up and
on the tailnet, then `sudo launchctl print system/io.olympus.ci-runner-heartbeat` and
`sudo cat /var/log/ci-runner-heartbeat.log` (failed pushes only); the loop's own state is in
`/var/db/ci-runner/state` (`last_wipe_ok`, `last_registration_timestamp`). A host retired on purpose keeps
`MacCIRunnerHeartbeatMissing` firing for 7 days; silence it in Alertmanager.

### Remove scale sets

- Remove ONLY the KVM scale set (keeps olympus-linux / olympus-gate):
  1. Delete the repository variable `VM_TEST_RUNNER` (jobs go back to hosted).
  2. PR removing `helmrelease-scale-set-kvm.yaml` and its line in `kustomization.yaml`;
     wait until `kubectl -n arc-runners get autoscalingrunnerset olympus-kvm` is gone.
  3. Same or next PR: remove `ci-runners-kvm` from `quota.yaml` and lower `ci-runners`
     back to the non-KVM numbers (12 pods, 8500m / 17Gi / 20 / 36Gi, 18Gi / 76Gi
     ephemeral, drop `requests.olympus.io/kvm`), remove `ci-runner-kvm` from
     `priorityclass.yaml`; delete `flux-kustomizations/kvm-device-plugin.yaml`, its line in
     `../kustomization.yaml` and the `../kvm-device-plugin/` directory (`prune: true`
     removes the namespace, DaemonSet, PriorityClass `ci-device-plugin` and the
     ValidatingAdmissionPolicy + binding).
  4. `kubectl label node <node> node-restriction.kubernetes.io/kvm-ci-` on each labelled node. The node keeps
     an `olympus.io/kvm` capacity of 0 in its status until the kubelet restarts; harmless.
- Removal, in TWO steps (removing everything at once deadlocks: the controller is
  deleted before it can remove the scale set's finalizers):
  1. PR removing ALL scale-set releases (`helmrelease-scale-set.yaml`,
     `helmrelease-scale-set-gate.yaml`, `helmrelease-scale-set-kvm.yaml` and their lines in
     `kustomization.yaml`); wait until
     `kubectl -n arc-runners get autoscalingrunnerset` is empty.
  2. PR removing the rest (delete `flux-kustomizations/arc.yaml` and its line in
     `../kustomization.yaml`; `prune: true` removes the app).
  3. Delete the 4 CRDs by hand, Helm/Flux never remove CRDs:
     `kubectl get crd -o name | grep actions.github.com | xargs kubectl delete`.
  4. Remove the device plugin and node labels as in steps 3 and 4 of the KVM-only removal.

## Runner image

`ghcr.io/nwlnexus/olympus-ci-runner@sha256:...` (public; Ubuntu 22.04, user `runner`
uid 1001, no sudo, actions runner 2.338.0 plus the repo toolchain). To bump: build with
`ci/runner/build.sh` in olympus-sdk (olympus-sdk#406), take the digest it prints, and
replace the digest in `helmrelease-scale-set.yaml` in one PR. Never use a tag.
`olympus-kvm` uses the KVM variant of the image (adds qemu-system-x86, qemu-utils and the
ssh client; same user, no sudo); bump its digest in `helmrelease-scale-set-kvm.yaml` and
re-run `bash vms/harness/vm.sh doctor` in a KVM job (it must print `accel   kvm`).

## Device plugin image (mirror)

`ghcr.io/nwlnexus/generic-device-plugin@sha256:66c8d5c270eb2b721f1064c549b9b7898152a6d2f0163380a5d37dc7636c20ff`
is a byte-identical mirror of upstream `ghcr.io/squat/generic-device-plugin:0.2.0`
(index digest `sha256:66c8d5c2...`, same value; linux/amd64, arm64, arm/v7 plus
attestations), source `github.com/squat/generic-device-plugin`, licence **Apache-2.0**
(redistribution allowed; the image is the upstream binary unmodified). We mirror so a
single-maintainer upstream registry cannot change or remove what we run. To bump:

```sh
gh auth token | skopeo login ghcr.io -u <user> --password-stdin
skopeo copy --all --preserve-digests docker://ghcr.io/squat/generic-device-plugin@sha256:<new> docker://ghcr.io/nwlnexus/generic-device-plugin:<tag>
skopeo logout ghcr.io
```

then update the digest in `../kvm-device-plugin/daemonset.yaml` AND `../kvm-device-plugin/vap.yaml`
in one PR (the policy rejects any other image). Review the upstream diff first: the plugin is root-equivalent on the node.

## Egress proxy (olympus-sdk#407)

Runner pods can reach any public IP, so a malicious job can exfiltrate whatever it can read.
NetworkPolicy (kube-router) cannot match hostnames, so egress goes through an allowlisting forward
proxy in its own namespace, `../ci-egress/` (squid, `ubuntu/squid` rock by digest, 2 replicas on
different nodes, PDB, PSA `restricted`, read-only root fs). Its policy admits TCP 3128 from
`arc-runners` only; its egress is DNS + the public internet with the runners' except-list, and squid
itself refuses internal destinations. It prefers nodes that are not control-plane (naraka-01, the
Mac VMs), away from the amd64 runners and etcd.

Staged, because a wrong allowlist breaks all CI:

1. **Log-only (live).** squid allows everything and logs one line per request
   (`egress method=CONNECT host=github.com port=443 status=200 ... ua="..."`; host and port only,
   never URL paths). The runner templates set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (both cases,
   all four scale sets). Direct egress stays allowed, so a tool that ignores the proxy env keeps
   working; it shows up as missing from the proxy log, not as a failed job.
2. **Allowlist from the logs.** Distinct hosts over real CI traffic from Loki (the otel-logs
   DaemonSet ships the pod logs):
   `sum by (host) (count_over_time({k8s_namespace_name="ci-egress"} |= "egress method=" | logfmt [7d]))`.
   Then squid enforces a `dstdomain` allowlist (CONNECT to 443 only); denials show as
   `status=403 result=TCP_DENIED`.
3. **Enforce at the network.** `egress-dns-and-internet` shrinks to DNS + the proxy (+ the LiteLLM
   exception for olympus-kvm), so nothing can bypass the proxy.

`NO_PROXY` keeps local and in-cluster traffic direct: `localhost`, `127.0.0.1`, `::1` (QEMU guests
are reached through hostfwd on 127.0.0.1 in the kvm pods), `.svc`, `.cluster.local`, `10.0.0.0/8`
(only for clients that understand CIDR; curl 7.81 in the runner image does not), the LiteLLM
Service (`litellm.inference.svc`, executor on olympus-kvm) and the pod's own IP.

Not proxied today (they ignore the env or never see it): the QEMU guests (user-mode NAT through the
pod's sockets; the executor's provision boot downloads node, uv and pnpm inside the guest, and some
VM suites fetch `dl.nwlnexus.io` inside the guest), Node's built-in `fetch()` without
`NODE_USE_ENV_PROXY=1`, and anything speaking non-HTTP (ssh, NTP). Phase 2 must pass the proxy into
those or accept that they fail closed under phase 3.

Monitoring: Prometheus alerts `CiEgressProxyDown` (no available replica, 2m), `CiEgressProxyDegraded`
(one replica, 30m) and `CiEgressProbeFailing` (blackbox HTTPS GET of `api.github.com/rate_limit` through
the proxy, job `blackbox-ci-egress`, 5m) in group `ci-egress-proxy`
(`../observability/prometheus-helmrelease.yaml`); the Loki ruler alert `CiEgressDenials` (more than 5
`status=403` lines in 10m, `../observability/loki-rules-ci-egress.yaml`). The runner templates also set
`WRANGLER_SEND_METRICS=false`, `TURBO_TELEMETRY_DISABLED=1` and `DO_NOT_TRACK=1`, so tool telemetry is
off at the source instead of showing up as denials. `squid -k parse` runs on every PR against the
pinned image (validate workflow).

The Flux Kustomization `arc` deliberately does **not** `dependsOn` `ci-egress`: a broken proxy would then
also block reconciling `arc`, i.e. the drain switch and the fallback below (removing the proxy env and
reverting the runner network policy), exactly when they are needed.

**If the proxy is down**, every job on these runners fails (the runner reaches GitHub through it).
Fallback, fastest first: (1) fix or roll back `../ci-egress/` (Flux Kustomization `ci-egress`
turns not-ready when its pods are not Ready); (2) PR removing the proxy env from the scale-set
templates (works while phase 3 is not in place; with phase 3, also revert the network policy);
(3) the hosted-runner fallback under "Drain, fallback and removal".

## Later (intentionally not included yet)

- macOS runners, beyond the heartbeat (Monitoring above). (1) Tailnet: `tag:mac-server` has no source grant, so
  mmini-01 and mmini-02 cannot push to `obs-otlp` yet. Narrowest fix, both owner decisions: tag the `otlp-ts`
  proxy (`tailscale.com/tags`, e.g. `tag:obs-otlp`) and grant `tag:mac-server` -> `tag:obs-otlp` on `tcp:4318`
  only. Job code cannot use it: the runner user's pf anchor blocks 100.64.0.0/10 and all IPv6 but `::1`.
  (2) The heartbeat runs on the host, so it cannot prove GitHub sees the runner online. For that, a GitHub-side
  probe: a fine-grained PAT (or a separate GitHub App) with only
  **Self-hosted runners: read** on the org, in 1Password, synced by ESO into `observability`, used by a
  blackbox `http_2xx` module on `https://api.github.com/orgs/nwlnexus/actions/runners?per_page=100`
  with `fail_if_body_not_matches_regexp` per host (`"name":"<host>-[0-9]{14}"[^}]*"status":"online"`)
  and an alert at 15 min. Deliberately NOT the `arc-github-app` key: that one can register runners
  org-wide and stays in the arc namespaces.
- Egress allowlist: phase 1 (log-only proxy) is live, phases 2 and 3 are open ("Egress proxy" above,
  olympus-sdk#407).

## Notes

- The runner group `olympus-ci` is org-wide by owner decision, so every private repo
  in the org shares this isolation boundary: ephemeral pods, quota, network policy, no SA token.
- Network policy is enforced by k3s' embedded kube-router controller. If someone adds
  `disable-network-policy` to the k3s config, the policies silently stop applying.
- kube-router programs a new pod's policy only after the pod starts (measured
  unfiltered window 0.2 to 0.7 s). Real runners are not exposed: `run.sh` talks to
  GitHub for seconds before any job code runs, and containerMode is unset.
- Runner pods have `automountServiceAccountToken: false`, `enableServiceLinks: false` (no Service env vars) and a service account without RBAC.
