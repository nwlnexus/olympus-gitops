# arc: CI runners on the cluster

GitHub's runner scale set controller (ARC) running ephemeral CI runner pods on
compute-hub. Design: `docs/superpowers/specs/2026-10-19-ci-runners-on-cluster-design.md`
in `nwlnexus/olympus-sdk`; epic `nwlnexus/olympus-sdk#383` (this directory implements #386 and #387).

**Status: staged.** The scale set is merged with `maxRunners: 0`: the controller,
listener, ExternalSecret, quota and policies come up and can be validated, but no
runner pod starts. Raising it is a separate one-line PR (first target 3) after the
preconditions below.

## Layout

| File | Purpose |
|------|---------|
| `namespace.yaml` | `arc-system` (controller + listeners), `arc-runners` (runner pods, PSA `restricted`), `arc-runners-kvm` (empty, baseline, documented PSA exception pending #390) |
| `priorityclass.yaml` | `ci-runner`, value -1000, `preemptionPolicy: Never` (below every other workload) |
| `quota.yaml`, `limitrange.yaml` | hard ceilings (12 pods: 4 runners + 8 gates; 8.5 CPU / 17 GiB requests, 20 CPU / 36 GiB limits) and default requests/limits for every container; `arc-runners-kvm` quota is 0 pods |
| `networkpolicy.yaml` | default-deny ingress; runner egress = DNS + public internet only (no IPv4 cluster, node, LAN or tailnet addresses); controller/listener egress adds the API server only |
| `externalsecret.yaml` | `arc-github-app` Secret (GitHub App credentials) from 1Password via ESO |
| `ocirepository.yaml` | both charts pinned by digest (`ghcr.io/actions/actions-runner-controller-charts`) |
| `helmrelease-controller.yaml` | `gha-runner-scale-set-controller` (release `arc`, CRDs `CreateReplace`, `watchSingleNamespace: arc-runners`, image pinned by digest) |
| `helmrelease-scale-set.yaml` | `gha-runner-scale-set` release `olympus-linux` (`runs-on: olympus-linux`), no container mode |
| `helmrelease-scale-set-gate.yaml` | scale set `olympus-gate` (`runs-on: olympus-gate`), tiny pods for the CI gate poller |

## Scale sets

All in `arc-runners`, same chart pin, same GitHub App Secret and runner group `olympus-ci`,
same hardening (restricted, uid 1001, no SA token, `ci-runner` priority, our runner image by digest).
Both are staged at `maxRunners: 0`; raise `olympus-linux` (first target 3) and `olympus-gate` (8) together.

| Scale set | For | Pods | Per pod (requests / limits) |
|-----------|-----|------|------------------------------|
| `olympus-linux` | CI jobs (lint, test, build) | max 4 | 2 CPU, 4 GiB / 4 CPU, 8 GiB; spread over the onodes via label `olympus.io/ci-runner` |
| `olympus-gate` | the CI gate workflow: a poller (bash, gh, jq) that waits up to 120 min for sibling workflows | max 8 | 50m, 128Mi, 256Mi ephemeral / 500m, 512Mi, 2Gi; label `olympus.io/ci-gate`, no spread |
| `olympus-kvm` (later, #390) | VM suites | 1 | see #390 |

The gate has its own pool on purpose: if it shared the 3 `olympus-linux` slots, three open
PRs would each hold a slot while waiting for jobs that can never be scheduled (deadlock).
The `arc-runners` quota (12 pods, requests 8.5 CPU / 17 GiB, limits 20 CPU / 36 GiB) is the
runner budget plus the gate budget. NetworkPolicies and the LimitRange select/apply to the
whole namespace, so gate pods get the same isolation. The controller (`watchSingleNamespace:
arc-runners`) serves any number of scale sets in that namespace; each adds one listener pod
in `arc-system` (quota 10 pods is enough for the controller and 2 to 3 listeners).

Charts are `0.15.0` (controller and scale set must always be bumped together; update
tag and digest of both OCIRepository objects). `watchSingleNamespace` removes the
cluster-wide ClusterRole; the consequence is that scale sets must live in
`arc-runners`, so the future KVM scale set (#390) must either also use `arc-runners`
or get a second controller.

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

## Preconditions before raising maxRunners

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

- Drain: set `maxRunners: 0` in `helmrelease-scale-set.yaml`, merge; no new runners
  start, running jobs finish. (See known issue #4715 when raising it again.)
- Fallback to hosted runners: set the repository variables (`RUNNER_LINUX` etc.)
  back to the hosted label (`ubuntu-latest`).
- Removal, in TWO steps (removing everything at once deadlocks: the controller is
  deleted before it can remove the scale set's finalizers):
  1. PR removing BOTH scale-set releases (`helmrelease-scale-set.yaml` and
     `helmrelease-scale-set-gate.yaml`, and their lines in `kustomization.yaml`); wait until
     `kubectl -n arc-runners get autoscalingrunnerset` is empty.
  2. PR removing the rest (delete `flux-kustomizations/arc.yaml` and its line in
     `../kustomization.yaml`; `prune: true` removes the app).
  3. Delete the 4 CRDs by hand, Helm/Flux never remove CRDs:
     `kubectl get crd -o name | grep actions.github.com | xargs kubectl delete`.

## Runner image

`ghcr.io/nwlnexus/olympus-ci-runner@sha256:...` (public; Ubuntu 22.04, user `runner`
uid 1001, no sudo, actions runner 2.338.0 plus the repo toolchain). To bump: build with
`ci/runner/build.sh` in olympus-sdk (olympus-sdk#406), take the digest it prints, and
replace the digest in `helmrelease-scale-set.yaml` in one PR. Never use a tag.

## Later (intentionally not included yet)

- KVM scale set (`olympus-kvm`, #390; `arc-runners-kvm` is empty with a 0-pod quota and
  deny-all policy). Its image variant digest is
  `ghcr.io/nwlnexus/olympus-ci-runner@sha256:b024514b2ce7a04d5483b8199081cf5e7c910dfd9adc6319afa4f723112cf137`.
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
- Runner pods have `automountServiceAccountToken: false` and a service account without RBAC.
