# Setting Up GoDaddy DNS with cert-manager for Let's Encrypt

This guide shows how to configure cert-manager to use GoDaddy DNS for DNS-01 challenges with Let's Encrypt.

---

## Overview

cert-manager uses DNS-01 challenges to prove domain ownership to Let's Encrypt. For GoDaddy, this requires:
- GoDaddy API credentials
- A Kubernetes Secret with API credentials
- A ClusterIssuer configured to use GoDaddy DNS provider

---

## Prerequisites

- **GoDaddy Account** with domain registration
- **kubectl** access to your Kubernetes cluster
- **cert-manager** deployed in `cert-manager` namespace

---

## Step 1: Generate GoDaddy API Token

1. **Log in to GoDaddy Developer Portal**: https://developer.godaddy.com
2. **Click "Get API Key"** or navigate to API Keys section
3. **Create New API Key**:
   - Give it a description (e.g., "Home Lab cert-manager")
   - Select **Account** permissions
   - Click **Create**
4. **Save your credentials**:
   - **API Key** (e.g., `abc123def456`)
   - **API Secret** (e.g., `xYz789abcDef123`)

> ⚠️ **Important**: Copy these credentials immediately - you won't see the secret again!

---

## Step 2: Create Kubernetes Secret

Create a secret to store your GoDaddy credentials:

```bash
kubectl create secret generic goadaddy-dns-creds \
  --from-literal=GO_DADDY_API_KEY="your-api-key-here" \
  --from-literal=GO_DADDY_API_SECRET="your-api-secret-here" \
  -n cert-manager
```

**Replace the placeholder values:**
- `your-api-key-here` → Your actual GoDaddy API key
- `your-api-secret-here` → Your actual GoDaddy API secret

### Verify the secret

```bash
kubectl get secret godaddy-dns-creds -n cert-manager -o yaml
```

---

## Step 3: Create ClusterIssuer

The ClusterIssuer configuration is in:
`clusters/util-server/networking/cert-manager/clusterissuer.yaml`

Before applying, **edit the file** to update:

1. **Email address** for Let's Encrypt notifications:
```yaml
email: your-email@example.com
```

2. **Your domain name** (you may need multiple issuers for different domains):
```yaml
zones:
  - example.com  # Replace with your actual domain
```

3. **Apply credentials** (from the secret created in Step 2):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: godaddy-dns-creds
  namespace: cert-manager
type: Opaque
stringData:
  GO_DADDY_API_KEY: "abc123def456"
  GO_DADDY_API_SECRET: "xYz789abcDef123"
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
- **Invalid credentials**: Check your GoDaddy API key/secret
- **Domain not found**: Ensure the domain is registered with GoDaddy
- **DNS not propagated**: Wait a few minutes after creating DNS records
- **Rate limiting**: Let's Encrypt has rate limits; wait for the next day if exceeded

---

## Step 5: Test with Staging Environment (Recommended)

Before using production Let's Encrypt, test with the staging environment:

1. **Create a staging ClusterIssuer** (optional but recommended):
```yaml
# Add to clusterissuer.yaml or create a new file:
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-account
    solvers:
      - dns01:
          dns01:
            provider: godaddy
          zones:
            - example.com
```

2. **Apply the staging ClusterIssuer**:
```bash
kubectl apply -f clusters/util-server/networking/cert-manager/clusterissuer-staging.yaml
```

3. **Verify the staging issuer**:
```bash
kubectl get clusterissuer letsencrypt-staging
```

4. **Create a test Certificate**:
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
    - test.example.com
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
EOF

kubectl apply -f cert-test.yaml
```

5. **Check the certificate status**:
```bash
kubectl get certificate test-cert -n cert-manager
kubectl describe certificate test-cert -n cert-manager
```

**If the staging certificate succeeds**, you're ready for production!

---

## Step 6: Deploy Production Certificate

Once your staging tests pass, create the production certificate using your `letsencrypt-prod` ClusterIssuer:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-prod-cert
  namespace: ai
spec:
  secretName: example-prod-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - ai.example.com
    - llm.example.com
    - search.example.com
  secretTemplate:
    annotations:
      cert-manager.io/acme-certificates: "true"
```

Apply it:
```bash
kubectl apply -f cert-production.yaml
```

Check status:
```bash
kubectl get certificates -n ai
kubectl describe certificate ai-prod-tls -n ai
```

---

## Domain Configuration in GoDaddy

For SSL certificates to work, you need DNS records in GoDaddy:

### For Internal DNS (UDM Pro)

These should resolve to your Traefik IP:

| Domain | Type | Value | TTL |
|---------|------|------|-----|
| `*.example.com` | A | `192.168.30.230` | 300 |

### For DNS-01 Challenge

GoDaddy will automatically create `_acme-challenge` records via the API during certificate issuance. You don't need to manually configure these.

---

## GoDaddy Rate Limits

GoDaddy API has rate limits that may affect certificate issuance:

- **50 requests per minute** per API key
- **2000 requests per day** per account

If you hit rate limits:
1. Wait a few minutes before retrying
2. Use certificate caching (don't delete and recreate certificates)
3. Consider increasing your API key's rate limits in GoDaddy developer portal

---

## Troubleshooting

### Certificate Pending Status

```bash
kubectl describe certificate your-cert -n ai
```

Common issues:

| Issue | Solution |
|------|-----|
| **DNS-01 challenge not ready** | Check GoDaddy credentials, wait for DNS propagation |
| **Rate limit exceeded** | Wait 24 hours or use staging environment |
| **Invalid domain** | Ensure domain is registered in GoDaddy account |
| **API timeout** | Check if GoDaddy API is accessible |

### Verify GoDaddy DNS Records

After certificate issuance, verify the records:

```bash
dig any.example.com
dig _acme-challenge.any.example.com
```

You should see the A record pointing to `192.168.30.230`.

---

## Cleanup

If you need to remove GoDaddy credentials:

```bash
kubectl delete secret godaddy-dns-creds -n cert-manager
```

---

## Related Documentation

- [cert-manager DNS-01 Challenge](https://cert-manager.io/docs/configuration/acme/dns01/)
- [GoDaddy API Documentation](https://developer.godaddy.com/refs/)
- [cert-manager GoDaddy Provider](https://cert-manager.io/docs/configuration/acme/dns01/godaddy/)

---

With GoDaddy DNS configured, cert-manager can automatically issue and renew SSL certificates for your applications through Let's Encrypt!
