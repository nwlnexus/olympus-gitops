# arc: CI runners on the cluster

GitHub's runner scale set controller (ARC) running ephemeral CI runner pods on
compute-hub. Design: `docs/superpowers/specs/2026-10-19-ci-runners-on-cluster-design.md`
in `nwlnexus/olympus-sdk`; epic `nwlnexus/olympus-sdk#383` (this directory implements #386 and #387).

## Layout

| File | Purpose |
|------|---------|
| `namespace.yaml` | `arc-system` (controller + listeners), `arc-runners` (runner pods, PSA `restricted`), `arc-runners-kvm` (empty, baseline, documented PSA exception pending #390) |
| `priorityclass.yaml` | `ci-runner`, value -1000, `preemptionPolicy: Never` (below every other workload) |
| `quota.yaml`, `limitrange.yaml` | hard ceilings (6 pods, 24 CPU / 48 GiB) and default requests/limits for every container |
| `networkpolicy.yaml` | default-deny ingress; runner egress = DNS + public internet only (no cluster, node, LAN or tailnet addresses); controller/listener egress adds the API server only |
| `externalsecret.yaml` | `arc-github-app` Secret (GitHub App credentials) from 1Password via ESO |
| `helmrepository.yaml` | OCI HelmRepository `ghcr.io/actions/actions-runner-controller-charts` |
| `helmrelease-controller.yaml` | `gha-runner-scale-set-controller` (release `arc`, CRDs `CreateReplace`) |
| `helmrelease-scale-set.yaml` | `gha-runner-scale-set` release `olympus-linux` (`runs-on: olympus-linux`), min 0 / max 4, no container mode |

Both charts are pinned to the same version (currently `0.15.0`); always bump them together.
The controller CRDs are not upgraded by Helm itself, hence `crds: CreateReplace`.

## Pending 1Password field (blocker for the listener)

ESO cannot read 1Password file attachments, and 1Password text fields flatten the
newlines of a PEM. The private key must therefore be stored base64-encoded on one
line in a concealed field named `private-key-b64` of item `arc-github-app`
(vault Dev):

```sh
base64 -w0 key.pem   # paste the output into the field `private-key-b64`
```

The ExternalSecret decodes it (`decodingStrategy: Base64`) back to the multi-line
PEM in Secret key `github_app_private_key`. `app-id` and `installation-id` are
plain fields. Until `private-key-b64` exists the ExternalSecret is not Ready and
the scale set cannot authenticate.

## Drain and fallback

- Drain now: set `maxRunners: 0` in `helmrelease-scale-set.yaml` values, merge;
  no new runner pods start, running jobs finish.
- Fallback to hosted runners: set the repository variables (`RUNNER_LINUX` etc.)
  back to the hosted label (`ubuntu-latest`); jobs stop being queued here.
- Full removal: delete `flux-kustomizations/arc.yaml` and its line in
  `../kustomization.yaml` (`prune: true` removes everything). The controller CRDs
  are removed with the HelmRelease only if Helm owns them; check
  `kubectl get crd | grep actions.github.com` afterwards.

## Intentionally not included yet

- KVM scale set (`olympus-kvm`, namespace `arc-runners-kvm` is empty): #390.
- Our Ubuntu 22.04 runner image pinned by digest: #388. The runner image here is
  the upstream `ghcr.io/actions/actions-runner` placeholder; do NOT use it for release builds.
- Controller/listener metrics, dashboards, alerts: #392 (no scrape job exists; arc-system allows no ingress).
- Per-host egress allowlist (GitHub, crates.io, npm, ghcr.io): needs an FQDN-aware policy engine; kube-router can only do CIDRs.

## Notes

- The runner group `olympus-ci` is org-wide by owner decision, so every private repo
  in the org shares this isolation boundary: ephemeral pods, quota, network policy, no SA token.
- Network policy is enforced by k3s' embedded kube-router controller. If someone adds
  `disable-network-policy` to the k3s config, the policies silently stop applying.
- Runner pods have `automountServiceAccountToken: false` and a service account without RBAC.
