# Loki + Promtail

Log aggregation. Loki stores logs; Promtail receives the UDM Pro syslog
stream over UDP and pushes to Loki.

## URLs

- Loki (LAN-only): `https://loki.caehomelab.com`
- Internal: `http://loki.ai.svc.cluster.local:3100`
- UDM syslog target (UDP): **`192.168.30.217:30014`**
  (NodePort → Promtail pod)

## Deploy

```
./scripts/deploy-loki.sh
# then add the Loki datasource to Grafana (deploy-grafana.sh does this
# automatically; rerun if you deploy Loki after Grafana).
```

## Configuration

- **In the repo:** Loki ConfigMap (single-binary, filesystem-on-NFS,
  15-day retention via `retention_period: 360h` + compactor
  `retention_enabled: true`), Promtail ConfigMap (UDP syslog receiver,
  relabel rules), Loki PVC (10 Gi on NFS), Loki Deployment pinned to
  `caelx002`, Promtail Deployment pinned to `util-server` (so the UDM
  syslog NodePort lands on a local pod).
- **Via the UDM:** UniFi Network → System Settings → Advanced → Syslog
  Server: host `192.168.30.217`, port `30014`, protocol UDP.

## Foot-guns

- **Loki is pinned to `caelx002`**, not `util-server`. Relieving
  `util-server` memory pressure was the reason — Loki + Infisical +
  Open WebUI on the control plane OOM'd. If you add a third worker,
  update `nodeSelector` in the Deployment.
- **Promtail is pinned to `util-server`** because that's where the
  UDM's syslog NodePort lands. It tolerates the
  `node-role.kubernetes.io/control-plane:NoSchedule` taint for that
  reason. Moving it would break UDM log intake.
- **`auth_enabled: false`** — anyone on the LAN can read the Loki UI
  via the ingress. Add a Traefik basic-auth middleware to the ingress
  if you need to protect it.
- **Retention is in-process** (Loki single-binary runs the compactor
  itself, not a separate Microservices-mode compactor). NFS is fine
  here because the chunks are append-mostly; if you move to
  Microservices mode, re-check the storage class.
