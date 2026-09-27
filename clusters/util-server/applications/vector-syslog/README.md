# Vector -- UDM syslog receiver (RFC 3164 -> Loki)

Vector listens for UDM Pro remote syslog on UDP 1514 and pushes to Loki as
`job=udm-syslog`. Replaces both the dead Promtail config and the
RFC-5424-only Alloy option.

## Why

Both Promtail's and Alloy's `loki.source.syslog` parsers only accept RFC 5424
formatted messages. The UDM sends RFC 3164 (BSD) syslog, so the packets were
being silently dropped with "expecting a version value in the range 1-999"
parse errors. Vector's `syslog` source handles RFC 3164 natively.

## Topology

```
UDM Pro (rsyslogd) --(syslog UDP)--> 192.168.30.217:30015
                                       (NodePort)
                                   vector-syslog service
                                   vector pod (util-server)
                                   source.syslog -> remap (labels + extract) -> sink.loki
                                   Loki (loki.ai.svc.cluster.local:3100)
                                   Grafana --{job="udm-syslog"}--> dashboard
```

## Files

- `kustomization.yaml` -- kustomize entry point
- `configmap.yaml`     -- the `vector.yaml` ConfigMap (generated)
- `vector.yaml`        -- the pipeline source-of-truth
- `deployment.yaml`    -- single-replica Deployment pinned to util-server
- `service.yaml`       -- NodePort 30015/UDP -> 1514

## Run

```sh
kubectl apply -k . -n ai
kubectl -n ai rollout restart deploy/vector-syslog
```

## Cutover plan

1. `kubectl apply -k` here.
2. Send a test packet to `192.168.30.217:30015`:
   ```python
   import socket,time
   s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
   s.sendto(f'<13>{time.strftime("%b %d %H:%M:%S")} testhost vector-test - - HELLO'.encode(),
            ("192.168.30.217",30015))
   ```
3. Verify in Loki: `{job="udm-syslog",source="udm"}` returns the line.
4. Repoint the UDM's `rsyslogd.port` from `30014` to `30015`:
   ```sh
   curl -sk -X PUT -H "X-API-KEY: $K" -H "Content-Type: application/json" \
     -d @- https://192.168.250.1/proxy/network/api/s/default/rest/setting/rsyslogd \
     <<< '{"key":"rsyslogd","ip":"192.168.30.217","port":30015,"enabled":true,...}'
   ```
5. Once verified, remove Promtail:
   - `kubectl -n ai delete svc promtail-syslog cm promtail-config deploy promtail`
   - Strip `promtail-` blocks and the `promtail-syslog` service from
     `applications/loki/kustomization.yaml`.

## Labels

| Label              | Source                                        |
|--------------------|-----------------------------------------------|
| `job`              | static: `udm-syslog`                          |
| `source`           | static: `udm`                                 |
| `host`             | RFC 3164 hostname (UDM name, e.g. `9050-Network`)|
| `app`              | RFC 3164 TAG                                  |
| `severity`         | RFC 3164 severity text (`info`, `warning`, ...)|
| `facility`         | RFC 3164 facility text                        |
| `event_category`   | parsed from `[CATEGORY]` prefix               |
| `event_subcategory`| parsed from `[...-SUBCATEGORY]` if present    |

## Retention

Loki retention is 360h (15d) globally. To match the 7-day ask, edit
`applications/loki/kustomization.yaml`:

```yaml
limits_config:
  retention_period: 168h   # 7 days
```
