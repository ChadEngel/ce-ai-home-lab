# Postgres

Shared Postgres for stateful apps that want to run >1 replica
(Grafana, Open WebUI — and Bifrost, pending upstream support). Single
instance on `util-server`, with daily logical backups to the NAS.

## URLs

- Internal: `postgres.ai.svc.cluster.local:5432`
- (No public URL.)

## Deploy

```
./scripts/deploy-postgres.sh
```

## Configuration

- **In the repo:** Deployment (pinned to `util-server`), PVC
  (`postgres-data`, on `local-path` because Postgres on NFS is a
  fsync/locking footgun), Service, and the daily backup CronJob
  (`backup.yaml`) that writes `.sql.gz` files to a NAS-mounted
  directory.
- **Credentials:** `postgres-credentials` Secret, synced from
  Infisical.

## Foot-guns

- **Why on `local-path`, not `nfs-client`.** Postgres on NFS is a
  well-known footgun (fsync + locking semantics). Since the pod is
  pinned to `util-server` by design, `local-path`'s node-local
  affinity is a feature, not a limitation. Backups go to the NAS via
  the CronJob.
- **Why pinned to the control plane.** The DB is deliberately
  separated from the disposable worker nodes. Putting it on a worker
  would add a new failure domain (losing that worker takes the data
  layer with it). The control plane is already a single point of
  failure for this k3s cluster — Postgres doesn't make that worse.
- **Single replica.** This is the actual single point of failure for
  the apps that depend on it. Until we add a second control plane
  + streaming replication, treat `util-server` as the one node that
  must not die.
