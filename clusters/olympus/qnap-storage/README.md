# QNAP iSCSI dynamic provisioning (compute-hub)

This directory is the **GitOps-controlled side** of QNAP iSCSI storage: it
defines the Trident backend, the StorageClass, and the credential
ExternalSecret. It mirrors `clusters/ai-hub/qnap-storage/` with per-cluster
values.

`qnap-iscsi` is **not** the default StorageClass on this cluster (local-path
is). Workloads must set `storageClassName: qnap-iscsi` explicitly.

## What GitOps manages (this dir)

| File | Purpose |
|------|---------|
| `externalsecret.yaml` | Pulls QNAP mgmt creds (`qnap-csi`) + per-cluster CHAP/portal (`compute-hub-qnap-iscsi`) from 1Password into the `qnap-trident-backend-creds` Secret in the `trident` namespace |
| `trident-backend.yaml` | `TridentBackendConfig` (driver `qnap-iscsi`, CHAP, `location=compute-hub` label) |
| `storageclass.yaml` | `qnap-iscsi` StorageClass selecting `location=compute-hub`, non-default |

## Prerequisites NOT managed here (bare-metal, vs ai-hub's Colima)

ai-hub ran k3s inside a Colima Lima VM, so iSCSI/multipath packages and the
CSI plugin were handled in the Colima provision script + ansible. These hubs
are **bare-metal k3s**, so the equivalent must be done on the real nodes:

1. **Node packages on every k3s node** (ansible / host-level):
   - `open-iscsi`, `multipath-tools`, `lsscsi`, `sg3-utils`
   - `iscsid` enabled + running; `iscsi_tcp` and `dm-multipath` kernel modules loaded
   - `/etc/iscsi/initiatorname.iscsi` set to a unique IQN per cluster
   - `/etc/multipath.conf` with single-path config for QNAP:
     ```
     defaults { user_friendly_names yes; find_multipaths no }
     blacklist { devnode "sd[a-z]+[0-9]+" }
     blacklist_exceptions { vendor "QNAP" }
     ```

2. **QNAP CSI Plugin (Trident fork) installed in-cluster** — provides the
   `csi.trident.qnap.io` provisioner and the `trident.qnap.io` CRDs
   (incl. `TridentBackendConfig`). Reuse the `qnap-csi-bootstrap` ansible role
   from olympus-infra (it clones github.com/qnap-dev/QNAP-CSI-PlugIn and helm
   installs from the local clone). Set the bare-metal host_vars:
   `qnap_csi_state: present`, `qnap_csi_kubeconfig: <node kubeconfig>`.
   Use driver `qnap-iscsi` (NOT `qnap-nas`).

3. **QNAP side**: a dedicated iSCSI target + storage pool for this cluster,
   CHAP enabled, HTTP management API on port 8080, HTTPS port 443.

4. **1Password items** (Dev vault):
   - `qnap-csi` — shared: `username`, `password` (QNAP mgmt API account)
   - `compute-hub-qnap-iscsi` — `storageAddress` (QNAP portal IP),
     `chapInitiatorUsername`, `chapInitiatorPassword`

## Ordering

The `qnap-storage` Flux Kustomization `dependsOn: external-secrets` (for the
ClusterSecretStore) but **cannot** depend on the Trident CRDs since those are
installed out-of-band by ansible. If the CRDs are not present yet the
Kustomization fails with `no matches for kind "TridentBackendConfig"`; it will
self-heal on the next reconcile once the plugin is installed.

## Security note: QNAP mgmt API over HTTP (https:"false", port 8080)

The `qnap-trident-backend-creds` Secret sets `https: "false"` / `port: 8080`,
so the QNAP admin credentials traverse the LAN in cleartext between the k3s
nodes and the NAS. This is a deliberate carry-over from the proven ai-hub
config: the QNAP CSI/Trident TLS path hardcodes port 443 and had cert-trust
issues during ai-hub bring-up, so we use the HTTP mgmt API. Traffic is
confined to the storage L2 LAN (not routed, not over Tailscale/WAN).

This is a known platform-wide tradeoff, not unique to these clusters. Revisit
when moving the QNAP mgmt API to validated HTTPS (set `https: "true"`,
`port: 443`, and configure Trident cert trust) — track alongside the ai-hub
backend, since all three clusters share this pattern.

## Lessons carried over from ai-hub

- Driver `qnap-iscsi` (the `qnap-nas` driver SIGSEGVs on ARM64; on amd64 it
  works but we standardize on `qnap-iscsi`).
- Credential Secret keys: `username`, `password`, `storageAddress`,
  `https: "false"`, `port: "8080"`, `chapInitiatorUsername`,
  `chapInitiatorPassword`.
- `serviceLevel: pool1` is the internal QNAP pool ID, not a display name.
- QNAP HTTPS must be on port 443 (Trident hardcodes it for the TLS path; we
  use HTTP 8080 for the mgmt API here).
- `reclaimPolicy: Retain` so PVs survive PVC deletion.
