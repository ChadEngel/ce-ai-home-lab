# Setting Up Cloudflare DNS with cert-manager for Let's Encrypt

This guide shows how to configure cert-manager to use Cloudflare DNS for DNS-01 challenges with Let's Encrypt.

---

## Overview

cert-manager uses DNS-01 challenges to prove domain ownership to Let's Encrypt. For Cloudflare, this requires:
- Cloudflare API Token (with specific permissions)
- A Kubernetes Secret with API credentials
- A ClusterIssuer configured to use Cloudflare DNS provider

### Why Cloudflare?

- ✅ **API Tokens**: More secure than API keys with limited scopes
- ✅ **Free Tier**: 500 million rules/month (generous for DNS-01 challenges)
- ✅ **Fast Propagation**: DNS updates propagate quickly globally
- ✅ **Wildcard Support**: Full wildcard support via `*.domain.com`
- ✅ **Cloudflare DNS**: Reliable, fast, and free for most use cases

---

## Prerequisites

- **Cloudflare Account** with domain registered
- **kubectl** access to your Kubernetes cluster
- **cert-manager** deployed in `cert-manager` namespace

---

## Step 1: Generate Cloudflare API Token

### Option A: Zone-Level Token (Recommended, More Secure)

This gives cert-manager permissions only for your specific domain:

1. **Log in to Cloudflare Dashboard**: https://dash.cloudflare.com
2. **Go to**: Profile → **API Tokens**
3. **Click**: **Create Token**
4. **Select Template**: Use template **Edit zone DNS**
5. **Configure Permissions**:
   - **Resource**: Zone
   - **Zone**: Select your domain (caehomelab.com)
   - **Permissions**: Zone → Zone → DNS → Edit
6. **Set Expiry**: At least 1 year recommended
7. **Review & Create**: Click **Continue to summary** then **Create Token**
8. **Copy the Token**: You'll only see it once - save it securely!

### Option B: Account-Level Token (If You Have Multiple Domains)

If you need cert-manager to manage DNS for multiple domains under your account:

1. **Log in to Cloudflare Dashboard**: https://dash.cloudflare.com
2. **Go to**: Profile → **API Tokens**
3. **Click**: **Create Token**
4. **Use Custom Token** (skip template)
5. **Set Permissions**:
   - **Zone Resources**: `*.account.zone_read` (read access for all zones)
   - **Zone DNS Resources**: `*.zone.cloudflare_api.zone:*` (full DNS management)
6. **Edit Resource**: `resource.id` → Your Account ID (get from URL or API)
7. **Set Expiry**: Recommended 1 year
8. **Continue to summary** → **Create Token**

> **Note**: Zone-level tokens (Option A) are more secure and recommended for single-domain setups.

### Required Permissions

Your Cloudflare API token needs these permissions:
- **Edit zone DNS** (to create/delete `_acme-challenge` records)
- **Read zone** (to verify current records)
- **Zone** read access (to see zone configuration)

---

## Step 2: Create Kubernetes Secret

Create a secret to store your Cloudflare token:

```bash
kubectl create secret generic cloudflare-dns-creds \
  --from-literal=CF_API_TOKEN="your-cloudflare-api-token-here" \
  -n cert-manager
```

**Replace the placeholder value:**
- `your-cloudflare-api-token-here` → Your actual Cloudflare API token

### Copy Your API Token from Cloudflare

When you create the token in Step 1, Cloudflare displays it on screen. Copy it now and paste it into the command:

```bash
kubectl create secret generic cloudflare-dns-creds \
  --from-literal=CF_API_TOKEN="vF_1234abcdefghijklmnopqrstuvwxyz_AbCdEf" \
  -n cert-manager
```

### Verify the Secret

```bash
kubectl get secret cloudflare-dns-creds -n cert-manager -o yaml
```

---

## Step 3: Create ClusterIssuer

The ClusterIssuer configuration is in:
`clusters/util-server/networking/cert-manager/clusterissuer.yaml`

Before applying, **edit the file** to update:

1. **Email address** for Let's Encrypt notifications:
```yaml
email: chad@engelmn.com
```

2. **Your domain name**:
```yaml
zones:
  - caehomelab.com  # Your actual domain
```

3. **Apply Cloudflare credentials**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-dns-creds
  namespace: cert-manager
type: Opaque
stringData:
  CF_API_TOKEN: "vF_1234abcdefghijklmnopqrstuvwxyz"
```

### Apply the ClusterIssuer

```bash
kubectl apply -f clusters/util-server/networking/cert-manager/clusterissuer.yaml
```

---

## Step 4: Verify ClusterIssuer is Ready

Check the status of your ClusterIssuer:

```bash
kubectl get clusterissuer letsencrypt-prod
```

Expected output:
```
NAME              STATUS   READY
letsencrypt-prod  True     True
```

**If it's not ready**, check for issues:

```bash
kubectl describe clusterissuer letsencrypt-prod
```

Common issues:
- **Invalid token**: Check your Cloudflare API token
- **Token permissions too limited**: Token needs DNS zone edit permissions
- **Zone not found**: Verify your domain is in Cloudflare
- **Token expired**: Generate a new token

---

## Step 5: Test with Staging Environment (Recommended)

Before using production Let's Encrypt, test with the staging environment:

### Create a Staging ClusterIssuer

```bash
cat > clusterissuer-staging.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: chad@engelmn.com
    privateKeySecretRef:
      name: letsencrypt-staging-account
    solvers:
      - dns01:
          dns01:
            provider: cloudflare
          zones:
            - caehomelab.com
EOF

kubectl apply -f clusterissuer-staging.yaml
```

### Test Certificate

```bash
cat > cert-test.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: cert-manager
spec:
  secretName: test-cert-tls
  dnsNames:
    - test.caehomelab.com
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
EOF

kubectl apply -f cert-test.yaml
```

### Check the certificate status:

```bash
kubectl get certificate test-cert -n cert-manager
kubectl describe certificate test-cert -n cert-manager
```

**If the staging certificate succeeds**, you're ready for production!

---

## Cloudflare DNS Configuration

### For SSL Certificate Issuance

Cloudflare will automatically create `_acme-challenge` records via the API during certificate issuance. You don't need to manually configure these.

### Subdomain DNS Records

For your internal services (UDM Pro DNS or external):

| Subdomain | Type | Value | TTL | Purpose |
|-----------|------|-------|-----|---------|
| `*.caehomelab.com` | A | `192.168.30.217` | Automatic | All services |
| `ai.caehomelab.com` | A | `192.168.30.217` | 300 | OpenWebUI |
| `llm.caehomelab.com` | A | `192.168.30.217` | 300 | Bifrost |
| `search.caehomelab.com` | A | `192.168.30.217` | 300 | SearXNG |
| `secrets.caehomelab.com` | A | `192.168.30.217` | 300 | Infisical |
| `grafana.caehomelab.com` | A | `192.168.30.217` | 300 | Grafana |

### DNS in Cloudflare Dashboard

1. Create a zone for `caehomelab.com` in Cloudflare
2. Add a wildcard A record:
   - **Name**: `*`
   - **IP**: `192.168.30.217`
   - **Proxy status**: "DNS Only" (proxied through Cloudflare won't work for Let's Encrypt)

### DNS Proxy Settings

For DNS-01 challenges, set proxy status to **DNS Only** (orange cloud off):
- This lets Let's Encrypt validate the challenge without Cloudflare interfering
- Traefik will still handle routing

---

## Cloudflare Rate Limits

Cloudflare DNS API has generous rate limits:
- **2,000 requests per 5 minutes** (per zone)
- **1,000,000 rules/month** (for Cloudflare API)

You're very unlikely to hit limits with certificate renewals occurring 4x/year.

---

## Troubleshooting

### Certificate Pending Status

```bash
kubectl describe certificate your-cert -n ai
```

Common issues:

| Issue | Solution |
|------|---|
| **DNS-01 challenge not ready** | Check Cloudflare token, verify DNS has propagated |
| **Rate limit exceeded** | Wait and retry (very rare with Cloudflare) |
| **Invalid domain** | Ensure domain is in Cloudflare zone |
| **Token permissions** | Verify token has DNS edit permissions |

### Verify Cloudflare Credentials

1. **Check secret exists**:
   ```bash
   kubectl get secret cloudflare-dns-creds -n cert-manager
   ```

2. **Verify token works** (optional, from cluster):
   ```bash
   kubectl exec -it <cert-manager-pod> -n cert-manager -- bash
   curl -s "https://api.cloudflare.com/client/v4/user/tokens/verify" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -H "Content-Type: application/json"
   ```

3. **Check Cloudflare dashboard** for `_acme-challenge` records during issuance

### Check Certificate Issuance Logs

```bash
kubectl logs -n cert-manager -l app=cert-manager --tail=100
```

---

## Domain Configuration in Cloudflare Dashboard

### Zone Setup

1. **Add Domain**: https://dash.cloudflare.com
2. **Add Site**: Enter `caehomelab.com`
3. **Choose Plan**: Free (for Let's Encrypt, no paid features needed)

### DNS Records for Your Services

Under **DNS** → **Records**:

| Type | Name | Content | Proxy | TTL |
|----|---|---------|-------|-----|
| A | `@` | `192.168.30.217` | DNS Only | Auto |
| A | `*` | `192.168.30.217` | DNS Only | Auto |
| A | `ai` | `192.168.30.217` | DNS Only | Auto |
| A | `llm` | `192.168.30.217` | DNS Only | Auto |
| A | `secrets` | `192.168.30.217` | DNS Only | Auto |
| A | `search` | `192.168.30.217` | DNS Only | Auto |
| A | `grafana` | `192.168.30.217` | DNS Only | Auto |

**Important**: Set all DNS records to **DNS Only** (gray cloud) for Let's Encrypt to work!

---

## Certificate Renewal

cert-manager automatically renews certificates before expiration. You don't need to manually intervene.

**To force a renewal** (testing):
```bash
kubectl delete certificate your-cert -n ai
```

The renewal check happens approximately 30 days before expiration. Monitor with:

```bash
kubectl get certificate -A
kubectl describe certificate your-cert -n ai
```

---

## Security Best Practices

### 1. Use Least Privilege Token
The API token should only have permissions for your specific domain, not your entire Cloudflare account.

### 2. Store Secrets Securely
The credentials are stored in Kubernetes Secrets (encrypted at rest with Kubernetes encryption).

### 3. Rotate Tokens Regularly
- Regenerate API tokens every 6-12 months
- Update the Kubernetes secret:
  ```bash
  kubectl create secret generic cloudflare-dns-creds \
    --from-literal=CF_API_TOKEN="new-token" \
    -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
  ```

### 4. Monitor Expiry
Set up monitoring for certificate expiry:
```bash
kubectl get certificates -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

---

## Cloudflare Features That Help

### Automatic HTTPS
Once certificates are issued through cert-manager, Cloudflare can automatically serve HTTPS. You can enable this in Cloudflare dashboard after certificates are in place.

### HTTPS Only
After certificates are issued and working, enable **HTTPS Only** mode in Cloudflare to force HTTPS redirects.

### SSL/TLS Mode
Set to **Full** or **Full (strict)** mode for end-to-end encryption between Cloudflare and your origin servers.

---

## Related Documentation

- [cert-manager Cloudflare Provider](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [Cloudflare API Tokens](https://developers.cloudflare.com/access/api/how-to/get-api-token-zone/)
- [Cloudflare Dashboard API](https://dash.cloudflare.com/)

---

With Cloudflare DNS configured, cert-manager can automatically issue and renew SSL certificates for your applications through Let's Encrypt! The combination of Cloudflare's fast DNS propagation and cert-manager's automation makes certificate management painless.

### Quick Start Summary

1. ✅ Get Cloudflare API Token
2. ✅ Create Kubernetes secret (`cloudflare-dns-creds`)
3. ✅ Update ClusterIssuer email to your real email
4. ✅ Apply ClusterIssuer
5. ✅ Wait for `Ready` status
6. ✅ Deploy applications with TLS!

Your applications will now automatically get SSL certificates and renew them! 🎉
