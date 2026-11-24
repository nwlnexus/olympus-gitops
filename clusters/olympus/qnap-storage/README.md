# QNAP iSCSI dynamic provisioning (compute-hub)

This directory is the **GitOps-controlled side** of QNAP iSCSI storage: it
defines the Trident backend, the StorageClass, and the credential
ExternalSecret for the compute-hub cluster.

`qnap-iscsi` is **not** the default StorageClass on this cluster (local-path
is). Workloads must set `storageClassName: qnap-iscsi` explicitly.

## What GitOps manages (this dir)

| File | Purpose |
|------|---------|
| `externalsecret.yaml` | Pulls QNAP mgmt creds (`qnap-csi`) + per-cluster CHAP/portal (`compute-hub-qnap-iscsi`) from 1Password into the `qnap-trident-backend-creds` Secret in the `trident` namespace |
| `trident-backend.yaml` | `TridentBackendConfig` (driver `qnap-iscsi`, CHAP, `location=compute-hub` label) |
| `storageclass.yaml` | `qnap-iscsi` StorageClass selecting `location=compute-hub`, non-default |

## Prerequisites NOT managed here (bare-metal)

compute-hub is **bare-metal k3s**, so the iSCSI/multipath packages and the CSI
plugin can't be baked into a VM image — they must be provisioned on the real
nodes (ansible / host-level):

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
nodes and the NAS. This is deliberate: the QNAP CSI/Trident TLS path hardcodes
port 443 and had cert-trust issues during bring-up, so we use the HTTP mgmt
API. Traffic is confined to the storage L2 LAN (not routed, not over
Tailscale/WAN).

Revisit when moving the QNAP mgmt API to validated HTTPS (set `https: "true"`,
`port: 443`, and configure Trident cert trust).

## QNAP CSI/Trident notes

- Driver `qnap-iscsi` (the `qnap-nas` driver SIGSEGVs on ARM64; on amd64 it
  works but we standardize on `qnap-iscsi`).
- Credential Secret keys: `username`, `password`, `storageAddress`,
  `https: "false"`, `port: "8080"`, `chapInitiatorUsername`,
  `chapInitiatorPassword`.
- `serviceLevel: pool1` is the internal QNAP pool ID, not a display name.
- QNAP HTTPS must be on port 443 (Trident hardcodes it for the TLS path; we
  use HTTP 8080 for the mgmt API here).
- `reclaimPolicy: Retain` so PVs survive PVC deletion.

## Runbook: qnap-iscsi volume ext4 aborted

Background: olympus-gitops#299. On 2026-11-17 08:19 UTC every node lost its iSCSI sessions to the QNAP for a
few seconds (`ping timeout of 5 secs expired` → `session recovery timed out after 5 secs` → `I/O error … WRITE`).
ext4 aborted the journal of 5 of the 8 qnap-iscsi volumes and every later write to them failed, with
`input/output error` (7.x kernels) or `read-only file system` (6.8). Prometheus could not store anything, Grafana
and Redpanda crash-looped, Loki and Portainer could not write, for 6 days. The host-side iSCSI timeouts are
tracked on the issue; this section is the cluster-side procedure.

### Detect

The alerts (Prometheus `storage-health` group in `../observability/prometheus-helmrelease.yaml`, Loki rule in
`../observability/loki-rules-storage.yaml`):

| Alert | Means |
|-------|-------|
| `PrometheusIngestionStopped`, and the healthchecks.io dead-man e-mail (the `Watchdog` only pings while samples are stored) | Prometheus stores nothing; its own volume is the usual cause. The absent()-based alerts it would trigger are inhibited. |
| `PodVolumeIOErrors` (Loki ruler, straight to Alertmanager) | A pod logs `input/output error` / `read-only file system`. Names the pod. |
| `NodeFilesystemReadOnly` | An ext4 mount went read-only; `persistentvolume` label names the PV. |
| `KubePodCrashLoopingLong` | A pod has been in CrashLoopBackOff for over 1h. |
| `NodeFilesystemDeviceError` | statfs fails for a reason other than permissions (host or NFS mounts). |
| `PrometheusWALWritesFailing`, `PrometheusTSDBMaintenanceFailing`, `PrometheusTSDBCorruption` | Prometheus TSDB write, compaction or corruption problems while it still ingests. |

No exporter exposes ext4 error counts or iSCSI session state; confirm on the node:

```sh
kubectl -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}'
kubectl -n <ns> get pod <pod> -o wide
```

Then on that node (LAN or Tailscale SSH):

```sh
sudo dmesg -T | grep -E 'EXT4-fs|connection.*error|session recovery|I/O error'
findmnt -n -o SOURCE --target /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv>/mount
sudo tune2fs -l /dev/mapper/<mpathX> | grep -E 'Filesystem state|FS Error count|First error|Last error'
sudo iscsiadm -m session -P 1 | grep -E 'Target:|iSCSI Session State'
sudo multipath -ll
```

A broken volume shows `EXT4-fs error … ext4_journal_check_start … Detected aborted journal` in dmesg and
`Filesystem state: clean with errors` (or `not clean with errors`) with a non-zero `FS Error count` in tune2fs.
The iSCSI sessions must be `LOGGED_IN` again before the repair; if not, fix the path first (QNAP, network,
`iscsid` on the node).

### Before you scale anything

1. Find the owner: `kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.ownerReferences[0].kind}'`
   (a ReplicaSet means a Deployment).
2. **StatefulSet: read the PVC retention policy first.**
   `kubectl -n <ns> get sts <name> -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'`.
   If `whenScaled` is `Delete`, scaling to 0 **deletes the PVC** (loki, 2026-11-24). Do not scale it: change the
   HelmRelease values to Retain/Retain in Git, let Flux apply it, read the policy again. `StatefulSetPVCAutoDelete`
   fires for any StatefulSet still set to Delete. Every StatefulSet in the cluster was Retain/Retain after #299.
3. The PV must be `Retain`: `kubectl get pv <pv> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'` (the
   `qnap-iscsi` StorageClass sets it).
4. Optional: `flux suspend helmrelease <name> -n <ns>` while you work, so a reconcile does not scale it back
   mid-repair; `flux resume` afterwards.

### Repair

Trident fscks an ext4 volume when it stages it on a node (`fsck.ext4` in `NodeStageVolume`), so a full unstage
and restage repairs it. Deleting the pod is not enough: a replacement on the same node can reuse the staged mount.

```sh
kubectl -n <ns> scale sts/<name> --replicas=0        # or deploy/<name>
kubectl -n <ns> wait --for=delete pod/<pod> --timeout=5m
kubectl get volumeattachment | grep <pv>              # wait until empty (unstaged, iSCSI logged out)
kubectl -n <ns> scale sts/<name> --replicas=1        # or the previous replica count
```

Trident's fsck shows in Loki: `{service_name="trident-node-linux"} |= "fsck.ext4"`. On 2026-11-24 it logged
`/dev/dm-1: recovering journal … contains a file system with errors, check forced.` If fsck stops with
`UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY`, the pod stays in ContainerCreating with a MountDevice error: leave
it scaled to 0 and hand it to the owner for a manual `e2fsck` on the node.

### Verify

- On the node that now mounts it: `sudo tune2fs -l /dev/mapper/<mpathX>` shows `Filesystem state: clean` and
  `FS Error count: 0` (or no error count line).
- `kubectl -n <ns> get pod <pod>` is Ready and its restart count stays put.
- The alerts clear: `PodVolumeIOErrors` about 35 min after the last error line (30m window),
  `NodeFilesystemReadOnly` and `PrometheusIngestionStopped` within minutes. For Prometheus,
  `count(up)` returns again and `PrometheusTSDBCorruption` may fire once for the first hour (the WAL replay
  dropped the corrupt tail).

### Recovery: a StatefulSet PVC deleted by its retention policy

If a StatefulSet with `whenScaled: Delete` was scaled to 0, its PVC was deleted and scaling back up created a new,
empty PV. The old PV is `Released` (Retain kept it and its data). To put the old volume back:

1. Set the retention policy to Retain/Retain in Git and let Flux apply it (see "Before you scale anything").
2. Note both PVs: `kubectl get pv | grep <ns>/<pvc>` (old: `Released`; new: `Bound`, created today).
3. Scale the StatefulSet to 0 and wait for the pod to go.
4. Optionally let Trident delete the empty volume's LUN with it: `kubectl patch pv <new-pv> -p
   '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'` (double-check it is the new, empty PV).
5. `kubectl -n <ns> delete pvc <pvc>` (frees the claim name; the new PV is released or deleted per step 4).
6. Make the old PV bindable to that claim name again by removing the stale claim identity:

   ```sh
   kubectl patch pv <old-pv> --type json \
     -p '[{"op":"remove","path":"/spec/claimRef/uid"},{"op":"remove","path":"/spec/claimRef/resourceVersion"}]'
   ```

   It turns `Available`, still pre-bound to `<ns>/<pvc>` by name.
7. Scale the StatefulSet to 1. It recreates the PVC from its template and the PV controller binds it to the
   pre-bound old PV. Check: `kubectl -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}'` is the old PV.
8. Without step 4, delete the leftover empty PV (`kubectl delete pv <new-pv>`) and its LUN on the QNAP
   (`iscsi-trident-<new-pv>`): with Retain, Trident leaves the LUN behind.
