#!/usr/bin/env python3
"""Generate scripts/grafana/dashboards/linux-host-overview.json.

Telegraf host metrics -> InfluxDB v2 bucket `host_metrics`, queried with Flux
through the existing influxdb datasource (uid dfdkew37wk1dse). Run install-
telegraf.sh on each host to populate it. A `host` multi-select variable (All
by default) filters every panel via `r.host =~ /${host:regex}/.

Label convention (matches the proven pod-resource-utilization pattern): end
every query with
  ... |> aggregateWindow(...) |> map(_label = <combined string>)
       |> group(columns: ["_label"]) |> keep(columns: ["_time","_value","_label"])
       |> yield(name: "...")
The `group(columns: ["_label"])` after aggregateWindow strips the `_start`/
`_stop` window columns that aggregateWindow adds to the group key (those were
causing `_value {_start=..., _stop=...}` labels). `keep()` then drops every
other column so the group key is exactly {_label} -> Grafana renders the series
as just the label value (e.g. "util-server cpu-total"), matching how the pod
dashboard renders just the pod name.

Noisy telegraf tags are filtered: net -> physical NICs only, diskio -> whole
disks only, disk -> exclude /sys/* pseudo-fs paths. For net/diskio the raw
_field (bytes_recv/bytes_sent, read_bytes/write_bytes) is mapped to a friendly
`dir` column (RX/TX, Read/Write) before being folded into _label.
"""
import json, os

OUT = os.path.join(os.path.dirname(__file__), "linux-host-overview.json")
DS = {"type": "influxdb", "uid": "dfdkew37wk1dse"}
HOST_FILTER = 'r.host =~ /${host:regex}/'


def query(measurement, fields, label_expr, name, agg="last",
          pre="", where=""):
    """Assemble one Flux query string.

    measurement/fields: telegraf measurement + _field(s) to filter.
    label_expr: a Flux expression producing the combined _label string
                (e.g. 'r.host + " " + r.cpu').
    name: the yield(name:) stream name.
    agg: aggregateWindow fn (mean/last/max).
    pre: extra Flux between the filter and aggregateWindow (map value, derivative,
         map dir) -- newline-joined.
    where: extra predicate ANDed into the filter.
    """
    if isinstance(fields, str):
        fcond = f'r._field == "{fields}"'
    else:
        fcond = " or ".join(f'r._field == "{f}"' for f in fields)
    pred = f'r._measurement == "{measurement}" and ({fcond}) and {HOST_FILTER}'
    if where:
        pred += f" and {where}"
    q = (
        'from(bucket: "host_metrics")\n'
        '  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n'
        f'  |> filter(fn: (r) => {pred})\n'
    )
    if pre:
        q += pre
    q += (
        '  |> aggregateWindow(every: v.windowPeriod, fn: ' + agg
        + ', createEmpty: false)\n'
        f'  |> map(fn: (r) => ({{ r with _label: {label_expr} }}))\n'
        '  |> group(columns: ["_label"])\n'
        '  |> keep(columns: ["_time", "_value", "_label"])\n'
        f'  |> yield(name: "{name}")'
    )
    return q


def panel(pid, ptype, title, x, y, w, h, queries, unit=None, opts=None):
    """queries: list of (refId, flux_str)."""
    p = {
        "id": pid, "type": ptype, "title": title,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "datasource": DS,
        "targets": [
            {"refId": r[0], "query": r[1], "queryType": "flux", "datasource": DS}
            for r in queries
        ],
        "fieldConfig": {"defaults": {}, "overrides": []},
    }
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    if opts:
        p["options"] = opts
    return p


# Physical NIC prefixes (enp/ens/eth/eno/wlan/wlp) -- drops docker/cni/flannel/veth/br noise
NET_IFACE = 'r.interface =~ /^(enp|ens|eth|eno|wlan|wlp)/'
# Whole disks only -- nvme0n1, sda, vda (excludes partitions nvme0n1p1, sda1 + loop/dm/sr0)
DISKIO_NAME = 'r.name =~ /^(nvme[0-9]+n[0-9]+|sd[a-z]|vd[a-z])$/'
# Real mount paths only -- drops /sys/firmware/efi/efivars and other sysfs pseudo-fs
DISK_PATH = 'r.path !~ /^\\/sys\\//'

panels = []

# 1. CPU usage % (per core) = 100 - usage_idle
panels.append(panel(
    1, "timeseries", "CPU Usage % (per core)", 0, 0, 12, 8,
    [("A", query("cpu", "usage_idle",
        'r.host + " " + r.cpu', "cpu_pct", agg="mean",
        pre='  |> map(fn: (r) => ({ r with _value: 100.0 - r._value }))\n'))],
    unit="percent",
    opts={"legend": {"displayMode": "table", "placement": "right"},
          "tooltip": {"mode": "multi", "sort": "desc"}}
))

# 2. Memory used % (gauge)
panels.append(panel(
    2, "gauge", "Memory Used %", 12, 0, 6, 8,
    [("A", query("mem", "used_percent", 'r.host', "mem_pct", agg="last"))],
    unit="percent",
    opts={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""}}
))

# 3. Load average (stat: load1 / load5 / load15)
panels.append(panel(
    3, "stat", "Load Average (1/5/15)", 18, 0, 6, 8,
    [("A", query("system", ["load1", "load5", "load15"],
        'r.host + " " + r._field', "load", agg="last"))],
    unit="short",
    opts={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
          "orientation": "horizontal"}
))

# 4. Memory usage (used / available, timeseries)
panels.append(panel(
    4, "timeseries", "Memory Usage", 0, 8, 12, 8,
    [("A", query("mem", ["used", "available"],
        'r.host + " " + r._field', "mem", agg="mean"))],
    unit="bytes",
    opts={"legend": {"displayMode": "table", "placement": "bottom"}}
))

# 5. Disk usage % per mount (bargauge)
panels.append(panel(
    5, "bargauge", "Disk Usage % (per mount)", 12, 8, 12, 8,
    [("A", query("disk", "used_percent", 'r.host + " " + r.path',
        "disk_pct", agg="last", where=DISK_PATH))],
    unit="percent",
    opts={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
          "orientation": "horizontal", "displayMode": "gradient"}
))

# 6. Network throughput (bytes/sec, derivative) -- physical NICs only
# map _field bytes_recv/bytes_sent -> friendly RX/TX (matches unifi `dir` pattern)
panels.append(panel(
    6, "timeseries", "Network Throughput (physical NICs)", 0, 16, 12, 8,
    [("A", query("net", ["bytes_recv", "bytes_sent"],
        'r.host + " " + r.interface + " " + (if r._field == "bytes_recv" then "RX" else "TX")',
        "net", agg="mean", where=NET_IFACE,
        pre='  |> derivative(unit: 1s, nonNegative: true)\n'))],
    unit="Bps",
    opts={"legend": {"displayMode": "table", "placement": "bottom"}}
))

# 7. Disk I/O (bytes/sec, derivative) -- whole disks only
# map _field read_bytes/write_bytes -> friendly Read/Write
panels.append(panel(
    7, "timeseries", "Disk I/O (whole disks)", 12, 16, 12, 8,
    [("A", query("diskio", ["read_bytes", "write_bytes"],
        'r.host + " " + r.name + " " + (if r._field == "read_bytes" then "Read" else "Write")',
        "diskio", agg="mean", where=DISKIO_NAME,
        pre='  |> derivative(unit: 1s, nonNegative: true)\n'))],
    unit="Bps",
    opts={"legend": {"displayMode": "table", "placement": "bottom"}}
))

# 8. CPU temperature
panels.append(panel(
    8, "timeseries", "CPU Temperature", 0, 24, 12, 8,
    [("A", query("temp", "temp", 'r.host + " " + r.sensor', "temp", agg="last"))],
    unit="celsius",
    opts={"legend": {"displayMode": "table", "placement": "bottom"}}
))

# 9. Process count + zombies (stat)
panels.append(panel(
    9, "stat", "Processes (total / zombies / sleeping)", 12, 24, 12, 8,
    [("A", query("processes", ["total", "zombies", "sleeping"],
        'r.host + " " + r._field', "proc", agg="last"))],
    unit="short",
    opts={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
          "orientation": "horizontal"}
))

dash = {
    "uid": "linux-host-overview",
    "title": "CE AI Lab — Linux Host Overview",
    "tags": ["linux", "ce-ai-lab", "telegraf"],
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "time": {"from": "now-1h", "to": "now"},
    "timezone": "browser",
    "graphTooltip": 1,
    "templating": {
        "list": [{
            "name": "host",
            "type": "query",
            "datasource": DS,
            "query": ('from(bucket: "host_metrics")\n'
                      '  |> range(start: -1h)\n'
                      '  |> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle")\n'
                      '  |> group(columns: ["host"])\n'
                      '  |> distinct(column: "host")\n'
                      '  |> keep(columns: ["_value"])'),
            "queryType": "flux",
            "includeAll": True,
            "multi": True,
            "allValue": ".*",
            "current": {"text": "All", "value": "$__all", "selected": True},
            "refresh": 1,
        }]
    },
    "panels": panels,
    "annotations": {"list": []},
}

with open(OUT, "w") as f:
    json.dump(dash, f, indent=2)
print(f"wrote {OUT} ({len(panels)} panels)")