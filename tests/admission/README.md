# Admission test bed for the atlas cluster actuator

`run.sh` checks the actuator's admission policy, `ValidatingAdmissionPolicy atlas-cluster-actuator-fields`
in [`clusters/olympus/atlas-system/actuator-admission.yaml`](../../clusters/olympus/atlas-system/actuator-admission.yaml),
on a throwaway API server. It needs no cluster credential (olympus-sdk#964).

```sh
tests/admission/run.sh                                  # the policy in this checkout
POLICY=/tmp/policy-copy.yaml tests/admission/run.sh     # another copy of the policy
KEEP_TMP=1 tests/admission/run.sh                       # keep the temp dir (logs, kubeconfig)
```

It needs `nix` with flakes. The script re-runs itself in `nix shell` with kube-apiserver,
kube-controller-manager, kubectl, etcd, openssl and gawk from a pinned nixpkgs (`NIXPKGS_REV` in
`run.sh`). The binaries come from cache.nixos.org. To use binaries already on `PATH` instead, set
`ADMISSION_TEST_IN_NIX=1`. A run takes about ten seconds once the binaries are cached. It prints one
line per row and exits 1 if any row fails.

## What it does

1. Starts etcd and kube-apiserver in a temp dir, both on random localhost ports. RBAC is on. The admin
   is a static token in `system:masters`, and the service-account keys are generated. It also starts
   kube-controller-manager with only the `validatingadmissionpolicy-status-controller`, which writes
   the policy's type-checking status. The temp dir, with its kubeconfig and kubectl cache, is removed
   on exit. `KUBECONFIG` is unset, and every kubectl call passes its own `--kubeconfig`, so
   `~/.kube` is never read or written.
2. Applies the Flux CRDs, taken from `clusters/olympus/flux-system/gotk-components.yaml`. Then it
   applies, as committed: the `atlas-system` namespace, `actuator-rbac.yaml`, `actuator-configmaps.yaml`
   and the policy with its binding. It waits until the policy status shows the policy was type-checked.
3. Server-side applies `fixtures.yaml` under field manager `kustomize-controller`, as Flux does. The
   fixtures are: the Kustomizations `flux-system`, `atlas-system`, `whoami` and `cert-manager`; the
   HelmRelease `arc-runners/olympus-gate`; the Deployments `whoami`, `kube-system/coredns`,
   `external-dns` and `atlas-system/atlas-cluster-actuator`, plus `flux-system/kustomize-controller`;
   and the DaemonSet `otel/node-exporter`. It also writes status through the status subresource under
   the controllers' managers. `flux` takes ownership of `requestedAt` on `cert-manager`, and
   `kubectl-rollout` takes ownership of `restartedAt` on `external-dns`, so the ownership-transfer rows
   are real.
4. Runs the matrix in `cases.sh` as `system:serviceaccount:atlas-system:atlas-cluster-actuator`. Most
   rows are `--dry-run=server`, like the live checks. A few rows are real writes; they are ordered so
   that they do not affect later rows.

## The matrix

| Ids | Source |
|---|---|
| `922-*` | Every row of the live table on olympus-sdk#922 (policy generation 1), including the policy status and `auth can-i --list` |
| `956-*` | Every row of the live table on olympus-sdk#956 (generation 2): root suspend, managedFields, ownership transfer, DaemonSet restart |
| `R-*` | The further dry runs of the #922 security review (labels, finalizers, ownerReferences, JSON patch, image change, `atlas-system`, scale, list, other ConfigMaps, Secrets, status through the main resource, CRD schema) |
| `X-*` | Added here: the dedupe ConfigMap grants, create, the status subresource, a second annotation, an annotation removed, the DaemonSet template generation set directly, a suspended root resumed and reconciled, and real writes |
| `P-*` | The policy on its own. A test-only ClusterRole gives the actuator create, delete and subresource writes, so these requests get past RBAC and the policy's own denial answers |

Each row expects one of four outcomes: `allow`; `policy`, a denial by this policy whose message must
contain the given text; `rbac`, a denial by authorization; or `invalid`, a rejection by the API schema.
The #922 table was taken before #956 bound `managedFields`, using kubectl's default field manager. The
actuator always patches as `atlas-cluster-actuator`, and the current policy requires that manager, so
the `922-*` rows use it too.

## What it proves, and what it does not

- It proves what the real API server admission chain decides for each request: authorization, schema,
  the strategies (for example the DaemonSet template-generation bump) and this policy's CEL. The policy
  and RBAC files are the committed ones, or the file named by `POLICY`. A policy change that breaks a
  row fails the run, and CI runs it on every change to `actuator-*`.
- **Version gap.** The test bed runs Kubernetes 1.35.4 (the pinned nixpkgs). compute-hub runs
  v1.35.9+k3s1. The minor version is the same and the patch versions are five apart. k3s's own patches
  are not included. When the cluster moves to a new minor version, move `NIXPKGS_REV` to a nixpkgs that
  ships that minor version.
- **No controllers run** except the policy status controller. Nothing reconciles the fixtures: no pods
  start, Flux does not revert a suspend, and the DaemonSet controller does not roll anything. Only what
  the API server does within the request is tested.
- The fixtures resemble the live objects but are not them. The policy compares fields generically, so
  values do not matter. Field ownership on the cluster may differ in detail, for example the managers
  of Helm-installed objects.
- It does not replace a final check on the cluster after a policy change. That check is
  `--as system:serviceaccount:atlas-system:atlas-cluster-actuator --dry-run=server`, run by the owner or
  with the break-glass kubeconfig. Agent hosts deliberately hold no `impersonate` permission
  (olympus-sdk#935, #964).
- A finding from this test bed (row `X-13`): the API server's DaemonSet strategy discards a direct
  change of `deprecated.daemonset.template.generation`. So the policy's dsGeneration validation never
  sees a jump; a jump is denied by the managedFields rule instead. The validation remains as defence in
  depth.
