# Homelab Kubernetes Build Notes
**Date:** 2026-06-25

## Purpose

This document captures the initial build, discoveries, lessons learned, and final architectural decisions made while building a new Kubernetes environment on a single-node k3s cluster.

This document should be considered the starting point for rebuilding the environment from Infrastructure as Code.

---

# Infrastructure

## Host

| Item | Value |
|------|------|
| Hostname | util-server |
| OS | Ubuntu 26.04 LTS |
| Kernel | 7.0.0-22-generic |
| Kubernetes | k3s v1.35.5+k3s1 |
| Runtime | containerd |
| Node Role | control-plane |
| Node IP | 192.168.30.217 |

Single-node cluster.

---

# Storage

## Initial Problem

Pods would not schedule.

Symptoms:

- Pending
- Evicted
- DiskPressure
- FreeDiskSpaceFailed
- ImageGCFailed
- ephemeral-storage threshold exceeded

Root filesystem was only 10GB.

```
Filesystem                         Size Used Avail
/dev/mapper/ubuntu--vg-ubuntu--lv 9.8G 8.4G 897M
```

---

## Root Cause

containerd stores images on the root filesystem.

Because the VM was originally created with a 10GB root filesystem, Kubernetes immediately entered DiskPressure.

---

## Resolution

Hypervisor disk was expanded.

Then:

```bash
sudo growpart /dev/nvme0n1 3

sudo pvresize /dev/nvme0n1p3

sudo lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv
```

Result:

```
Filesystem                         Size Used Avail
/dev/mapper/ubuntu--vg-ubuntu--lv 48G 8.4G 38G
```

DiskPressure disappeared and pods scheduled normally.

---

# NFS Storage

The VM already mounts:

```
192.168.30.121:/data/pod_data
```

mounted as

```
/data
```

All Kubernetes persistent storage should reside on this NFS share.

**Do NOT use hostPath.**

Instead install:

```
nfs-subdir-external-provisioner
```

StorageClass:

```
nfs-client
```

which should become the default StorageClass.

Installation:

```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

helm repo update

helm install nfs-storage \
nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
--namespace nfs-storage \
--create-namespace \
--set nfs.server=192.168.30.121 \
--set nfs.path=/data/pod_data \
--set storageClass.name=nfs-client \
--set storageClass.defaultClass=true
```

---

# Kubernetes Networking

Default k3s installation includes

- CoreDNS
- Traefik
- Metrics Server
- Local Path Provisioner

Current services:

```
kubectl get svc -A
```

```
kube-system
    traefik

External IP:
192.168.30.230
```

Important discovery:

Traefik already owns the MetalLB address.

Because of this, applications should **NOT** receive their own LoadBalancer IP.

Instead everything should be routed through Traefik using Ingress.

---

# MetalLB

Installed successfully.

Address pool:

```
192.168.30.230-192.168.30.240
```

Discovered:

Traefik already consumes

```
192.168.30.230
```

Attempting to assign the same address to Open WebUI resulted in:

```
Failed to allocate IP

address already in use by kube-system/traefik
```

Decision:

Keep Traefik as the single ingress point.

---

# DNS

Internal DNS is provided by:

```
UDM Pro
```

Example records:

```
ai.caehomelab.com

grafana.caehomelab.com

search.caehomelab.com

ha.caehomelab.com
```

All resolve internally to

```
192.168.30.230
```

(or the Traefik service IP)

---

# HTTPS

Requirements

- Internal only
- No public access
- Trusted certificate
- Works over LAN
- Works through Tailscale

Decision:

Use

```
cert-manager
```

with

```
Let's Encrypt
DNS-01
```

Important:

Public DNS is used **only** for certificate validation.

Internal clients resolve through the UDM Pro.

No inbound port forwarding is required.

---

# Remote Access

Remote connectivity will use

```
Tailscale
```

Desired experience:

Whether on LAN or connected through Tailscale, applications are accessed using the exact same URLs.

Example:

```
https://ai.caehomelab.com

https://grafana.caehomelab.com

https://search.caehomelab.com
```

---

# Applications

Namespace

```
ai
```

Applications

```
Open WebUI

MCPO

SearXNG

Later:
Ollama
```

---

## Open WebUI

Image

```
ghcr.io/open-webui/open-webui:main
```

Container Port

```
8080
```

Persistent Storage

```
/app/backend/data
```

PVC

```
StorageClass

nfs-client
```

Expose

```
Ingress
```

NOT

```
LoadBalancer
```

---

## MCPO

Image

```
ghcr.io/open-webui/mcpo:main
```

Port

```
8000
```

Should remain

```
ClusterIP
```

Only Open WebUI should communicate with it.

---

## SearXNG

Image

```
searxng/searxng
```

Port

```
8080
```

Expose

Either

```
Ingress
```

or

```
ClusterIP
```

depending on whether browser access is desired.

---

# Architecture

Final architecture

```
                    Internet
                        |
        Public DNS Provider
       (Only DNS-01 validation)
                        |
                        |
                 cert-manager
                        |
--------------------------------------------------

                 Internal Network

                   UDM Pro DNS

                        |

                  ai.caehomelab.com
                        |

                 192.168.30.230

                        |

                   Traefik Ingress

             +-----------+------------+

             |                        |

        Open WebUI               SearXNG

             |

           MCPO

      (ClusterIP only)
```

---

# Repository Layout

Recommended Git repository

```
homelab-k8s/

README.md

clusters/

    util-server/

        namespaces/

        networking/

            metallb/

            traefik/

            cert-manager/

        storage/

            nfs/

        applications/

            openwebui/

            mcpo/

            searxng/

            ollama/

scripts/

docs/
```

Everything should be committed.

No manual kubectl apply commands after the initial bootstrap.

---

# Deployment Strategy

Infrastructure first

1. NFS Storage
2. Traefik
3. cert-manager
4. DNS
5. Applications

Applications should use either

Helm

or

Kustomize

with all values committed to Git.

---

# Validation Commands

Cluster

```bash
kubectl get nodes

kubectl get pods -A

kubectl get svc -A
```

Storage

```bash
kubectl get pvc -A

kubectl get storageclass
```

Ingress

```bash
kubectl get ingress -A
```

Certificates

```bash
kubectl get certificates -A

kubectl describe certificate
```

---

# Lessons Learned

1. Expand root storage immediately after installing Ubuntu.
2. Kubernetes image storage depends on the root filesystem.
3. DiskPressure prevents scheduling.
4. NFS should be consumed through a Kubernetes StorageClass.
5. Avoid hostPath.
6. Use Traefik as the only ingress.
7. Use cert-manager with DNS-01.
8. Internal DNS is independent of Let's Encrypt validation.
9. Keep applications behind Ingress instead of assigning individual LoadBalancer IPs.
10. Everything should be reproducible from Git.

---

# Current Cluster State

Current cluster has been cleaned.

Namespaces:

```
default

kube-system

kube-public

kube-node-lease
```

Running Services

```
CoreDNS

Metrics Server

Traefik

Local Path Provisioner
```

Traefik currently owns

```
192.168.30.230
```

No applications remain deployed.

The environment is ready for a clean Git-based rebuild.

---

# Next Session

1. Create Git repository.
2. Build repository structure.
3. Commit bootstrap manifests.
4. Install NFS provisioner.
5. Install cert-manager.
6. Configure DNS-01.
7. Configure Traefik Ingress.
8. Deploy Open WebUI.
9. Deploy MCPO.
10. Deploy SearXNG.
11. Add monitoring.
12. Add GitOps (FluxCD or ArgoCD) if desired.

Goal:

A fully reproducible Kubernetes environment built entirely from source control.