# NFS subdir external provisioner

The `nfs-client` StorageClass is backed by the
[kubernetes-sigs/nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
running in the `ai` namespace. It provisions `PersistentVolume`s as
subdirectories of the NFS export `192.168.30.121:/data/pod_data`.

## Canonical manifests (apply from this repo)

This directory is the source of truth for the provisioner. Helm is **not**
used to manage it anymore (the original `nfs-storage` Helm release was
replaced by raw manifests). Apply with:

```bash
kubectl apply -k clusters/util-server/storage/nfs/
```

Resources created:

| File                 | Resource                                                                 |
|----------------------|--------------------------------------------------------------------------|
| `serviceaccount.yaml`| `ServiceAccount/nfs-storage-nfs-subdir-external-provisioner` (ns `ai`)   |
| `rbac.yaml`          | `ClusterRole/nfs-provisioner-clusterrole` + `ClusterRoleBinding`          |
| `storageclass.yaml`  | `StorageClass/nfs-client` (default, `Retain`, expandable)                |
| `deployment.yaml`    | `Deployment/nfs-storage-nfs-subdir-external-provisioner` (1 replica)      |

`nfs-subdir-external-provisioner-values.yaml` is kept for reference / for
anyone who prefers the Helm chart; it mirrors these manifests.

## Why leader election is disabled

The provisioner runs a **single replica** on a **single-node** k3s cluster, so
there is no other replica to contend with for leadership — leader election
provides no benefit. With it enabled (the upstream default), any transient
kube-apiserver latency on this shared node makes the lease-renewal `PUT` to
`10.43.0.1:443` exceed its ~10s deadline; the provisioner then logs
`leaderelection lost` (exit 255) and restarts. That loop produced **115
restarts in 21 days**. Setting `ENABLE_LEADER_ELECTION=false` removes the
failure mode entirely.

If this ever becomes a multi-replica / multi-node deployment, re-enable leader
election and tune the lease durations instead of disabling it.

## NFS server prerequisites

See [`PREREQUISITES.md`](../../../PREREQUISITES.md) and
[`persistant_nfs_mount.md`](../../../persistant_nfs_mount.md):

- NFS server exporting `192.168.30.121:/data/pod_data`
- `nfs-common` installed on the k3s node