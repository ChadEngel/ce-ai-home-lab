# Rotating the Placeholder Credentials

> Written 2026-08 after an audit found four committed placeholder values are
> **live in the cluster**. Everything is LAN-only, so urgency is low, but these
> should be rotated to real values. Do them in the order below — easiest first.
>
> Verify current values:
> ```bash
> kubectl get secret grafana-secrets   -n ai -o jsonpath='{.data.admin-password}' | base64 -d; echo
> kubectl get secret infisical-secrets -n ai -o jsonpath='{.data.AUTH_SECRET}'    | base64 -d; echo
> kubectl get secret infisical-secrets -n ai -o jsonpath='{.data.ENCRYPTION_KEY}' | base64 -d; echo
> kubectl get secret infisical-db-creds -n ai -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
> ```

## 1. Grafana admin password (safe, do first)

The value lives in `clusters/util-server/applications/grafana/kustomization.yaml`
(`grafana-secrets` Secret). Generate, apply, restart:

```bash
NEW_PW=$(openssl rand -base64 24)
# edit kustomization.yaml admin-password by hand (or via Infisical sync, preferred long-term),
# then:
kubectl apply -n ai -f clusters/util-server/applications/grafana/kustomization.yaml
kubectl rollout restart deploy/grafana -n ai
echo "new password: $NEW_PW"   # store it in Infisical as GRAFANA_ADMIN_PASSWORD
```

Long-term fix: move `grafana-secrets` under an InfisicalSecret sync (same
pattern as `influxdb-secrets-sync`) and delete the inline Secret from the
manifest so git never sees the value again.

## 2. Infisical AUTH_SECRET (logs everyone out)

Signs session JWTs. Rotating invalidates all sessions (users re-login) and any
short-lived tokens minted from them. Machine Identity clientSecrets survive
(they are stored hashed/encrypted separately).

```bash
NEW=$(openssl rand -hex 32)   # must be >= 32 chars
# put NEW into kustomization.yaml infisical-secrets.AUTH_SECRET, then:
kubectl apply -n ai -f clusters/util-server/applications/infisical/kustomization.yaml
kubectl rollout restart deploy/infisical -n ai
```

Then log back in at https://secrets.caehomelab.com and store the value in the
`secret-management` project for reference.

## 3. Infisical Postgres password (brief downtime)

Coordinated change across the DB and the app (the app reads the full
`DB_CONNECTION_URI`, which embeds the password — update BOTH keys together).

```bash
NEW=$(openssl rand -hex 16)
# 1. exec into postgres and set it:
kubectl exec -it deploy/infisical-db -n ai -- sh -c \
  "psql -U infisical -c \"ALTER USER infisical WITH PASSWORD '$NEW';\""
# 2. update POSTGRES_PASSWORD *and* DB_CONNECTION_URI in kustomization.yaml, then:
kubectl apply -n ai -f clusters/util-server/applications/infisical/kustomization.yaml
kubectl rollout restart deploy/infisical -n ai
```

If the app fails to reconnect, check you updated `DB_CONNECTION_URI` too.

## 4. Infisical ENCRYPTION_KEY (⚠️ destructive if done wrong)

This key encrypts **every secret stored inside Infisical at rest**. Changing it
without re-encrypting makes all existing secrets permanently unreadable. There
is no online rotation — the safe path is export → rotate → re-import:

```bash
# 1. Export every secret out of Infisical FIRST (UI per-environment export,
#    or CLI):  infisical secrets --env prod --format json > backup.json
#    Verify backup.json actually contains your values before proceeding!
# 2. Generate the new key:
openssl rand -hex 16   # ENCRYPTION_KEY is a 32-char ASCII string (AES-128)
# 3. Update ENCRYPTION_KEY in kustomization.yaml, apply, restart infisical.
# 4. Re-create/import the secrets through the UI or CLI from backup.json.
# 5. Spot-check: openwebui/bifrost/unpoller pods still resolve their synced
#    secrets (operator re-syncs within ~60s).
```

Because this key protects Cloudflare DNS + InfluxDB + SSH keys, do step 1 on a
machine you trust and keep `backup.json` off shared storage.

## Repo hygiene note

These values were removed-from-git-visibility only insofar as they remain
placeholders in the manifests on purpose: the manifests need *some* value to
stay applicable, and Infisical itself can't bootstrap its own encryption key
from itself (chicken-and-egg). The convention elsewhere in this repo
(`cloudflare-secrets.yaml` intentionally empty + operator-managed) is the model;
`infisical-secrets` / `infisical-db-creds` / `grafana-secrets` should migrate to
that pattern once real values are set.
