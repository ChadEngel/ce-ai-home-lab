# CE AI Lab  – Grafana Monitoring Folder

This folder contains a sample Grafana dashboard you can import into your Grafana instance to monitor a Kubernetes cluster.

## Prerequisites
- Grafana (v8+) installed and reachable.
- A metrics backend:
   * **Prometheus** is the recommended source; ensure it scrapes `metrics-server`, `node-exporter`, etc.  
   * **InfluxDB** – you can add an InfluxDB data source in Grafana if your metrics are forwarded there.

## How to Use
1. Open Grafana → **+** → **Import**.  
2. Paste the contents of `k8s-monitoring.json` (or upload the file) into the import dialog.  
3. Choose the appropriate data source (**Prometheus** or **InfluxDB**).  
4. Click **Import**. The dashboard will appear and begin showing real‑time metrics.

## Customization
- Adjust panel queries to match your metric naming conventions.  
- Add extra panels for memory, network, alerts, etc., using Grafana Explore.

> This folder does not modify any existing configuration; it merely provides files you can add to your environment.
