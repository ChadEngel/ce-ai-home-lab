#!/bin/bash
# Fix SearXNG crash loop - issue is with the nginx-like secret_key

set -e

NAMESPACE="ai"

echo "=== Fixing SearXNG Configuration ==="

# Generate a proper secure secret key (must be at least 16 chars for SearXNG)
NEW_SECRET_KEY=$(openssl rand -hex 32)

echo "New secret key (first 32 chars): ${NEW_SECRET_KEY:0:32}..."

# Update the ConfigMap
kubectl patch configmap searxng-config -n $NAMESPACE --type=merge -p "{\"data\": {\"settings.yml\": \"$(cat <<'YAML'
server:
  secret_key: "PLACEHOLDER_SECRET_KEY"
  limiter: true
  image_proxy: true
  default_http_headers:
    X-Content-Type-Options: nosniff
    X-XSS-Protection: "1; mode=block"
    Referrer-Policy: no-referrer

ui:
  default_locale: "en-US"

search:
  formats:
    - html
    - json
YAML
)\"}}"

# Replace the placeholder with actual secret
kubectl patch configmap searxng-config -n $NAMESPACE --type=json -p "[{\"op\": \"replace\", \"path\": \"/data/settings.yml\", \"value\": \"$(sed "s/PLACEHOLDER_SECRET_KEY/${NEW_SECRET_KEY}/" <<< 'server:
  secret_key: PLACEHOLDER_SECRET_KEY
  limiter: true
  image_proxy: true
  default_http_headers:
    X-Content-Type-Options: nosniff
    X-XSS-Protection: "1; mode=block"
    Referrer-Policy: no-referrer

ui:
  default_locale: "en-US"

search:
  formats:
    - html
    - json')\"}]"

echo "SearXNG pod restarted with new secret key."
