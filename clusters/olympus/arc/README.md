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
| `networkpolicy.yaml` | default-deny ingress; runner egress = DNS + public internet only (no IPv4 cluster, node, LAN or tailnet addresses), plus `egress-litellm-kvm`: pods labelled `olympus.io/ci-kvm` (olympus-kvm only) may reach the `inference` LiteLLM pods on TCP 4000 (executor, olympus-sdk#642); controller/listener egress adds the API server only |
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
tainted `olympus.io/arch=arm64:NoSchedule` (6 vCPU / 12 GiB, kubelet reserves as on the onodes). Every
other image in the cluster is amd64, so the taint keeps everything else off; only workloads that opt in
tolerate it. `olympus-arm64` is a copy of `olympus-linux` with: `nodeSelector`
`kubernetes.io/arch: arm64` + `olympus.io/host: mac-mini`, a toleration for the taint, `maxRunners: 2`
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

## Monitoring watch items

During the first CI runs watch etcd I/O: `etcd_disk_wal_fsync_duration_seconds` at
`127.0.0.1:2381/metrics` on the onodes (baseline p99.98 under 8 ms). Pull the
alerts in #392 forward before raising maxRunners.

## Drain, fallback and removal

- Drain: set `maxRunners: 0` in `helmrelease-scale-set.yaml` (and/or `-gate`, `-kvm`),
  merge; no new runners start, running jobs finish. (See known issue #4715 when raising it again.)
- Fallback to hosted runners: set the repository variables (`RUNNER_LINUX` etc.)
  back to the hosted label (`ubuntu-latest`); for the VM suites delete `VM_TEST_RUNNER`
  (the workflow falls back to `ubuntu-latest` and re-enables KVM with udev there).
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

## Later (intentionally not included yet)

- Controller/listener metrics, dashboards, alerts: #392 (no scrape job exists; arc-system allows no ingress).
- Egress allowlist: runners can reach any public IP, so a malicious job can exfiltrate
  anything it can read (repository secrets exposed to the job). Standard NetworkPolicy
  and kube-router cannot match hostnames. Follow-up: an allowlisting forward proxy in its
  own namespace with runner egress limited to it (tracked in a separate issue).

## Notes

- The runner group `olympus-ci` is org-wide by owner decision, so every private repo
  in the org shares this isolation boundary: ephemeral pods, quota, network policy, no SA token.
- Network policy is enforced by k3s' embedded kube-router controller. If someone adds
  `disable-network-policy` to the k3s config, the policies silently stop applying.
- kube-router programs a new pod's policy only after the pod starts (measured
  unfiltered window 0.2 to 0.7 s). Real runners are not exposed: `run.sh` talks to
  GitHub for seconds before any job code runs, and containerMode is unset.
- Runner pods have `automountServiceAccountToken: false`, `enableServiceLinks: false` (no Service env vars) and a service account without RBAC.
