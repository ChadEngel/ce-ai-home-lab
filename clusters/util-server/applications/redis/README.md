# Redis

Small shared Redis for multi-replica coordination. Two consumers today:
Grafana (alert deduplication via `ha_redis_address`) and Open WebUI
(websocket sticky-session via `WEBSOCKET_REDIS_URL`).

## URLs

- Internal: `redis.ai.svc.cluster.local:6379`
- (No public URL.)

## Deploy

```
kubectl apply -k clusters/util-server/applications/redis/
```

No per-app `deploy-redis.sh` — Redis is a dependency of the other
multi-replica apps and is expected to be up before them.

## Configuration

- **In the repo:** Service + Deployment. **No PVC** — this is
  ephemeral coordination state, not data.
- **`--save "" --appendonly no`** — explicitly no persistence, by
  design. If Redis restarts, alerting re-elects and websockets
  reconnect. Nothing here is worth backing up.

## Foot-guns

- **Separate from `infisical-redis`.** This is deliberately NOT the
  same instance as the one Infisical uses. Mixing keyspaces would
  couple unrelated failure domains (flushing one would break the
  other).
- **Single replica.** Coordination only needs one node. If you scale
  beyond one, you'd need Sentinel — which is more machinery than
  this lab needs.
