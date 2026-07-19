#!/usr/bin/env bash
# infisical-agent-setup.sh — one-time setup for non-human (Machine Identity)
# access to the self-hosted Infisical at https://secrets.caehomelab.com.
#
# Creates a 0600 creds file at ~/.config/ce-ai-lab/infisical-agent.env
# holding the Machine Identity's clientId/clientSecret + project defaults,
# then verifies a Universal Auth login succeeds and the identity can read
# the homelab secrets.
#
# Run on any host that should be able to access Infisical secrets:
#     ./scripts/infisical-agent-setup.sh
#
# After setup, source the helper and use it:
#     source scripts/infisical-agent.sh
#     infs secrets                 # list
#     infs get CLOUDFLARE_API_TOKEN
#     infs set INFLUXDB_TOKEN=...  # rotate (Editor role required)
#
# Re-running is safe — it overwrites the creds file (after confirming).

set -euo pipefail

CREDS_FILE="${INFISICAL_AGENT_CREDS:-$HOME/.config/ce-ai-lab/infisical-agent.env}"
DEFAULT_DOMAIN="https://secrets.caehomelab.com/api"
DEFAULT_PROJECT_ID="c8c51c11-2b4e-46d7-a97a-3e220ea59f7f"
DEFAULT_PROJECT_SLUG="caehomelab-v1q6"
DEFAULT_ENV="prod"
DEFAULT_PATH="/"

echo "=== Infisical Machine Identity setup ==="
echo "  creds file: $CREDS_FILE"
echo ""

if [ -f "$CREDS_FILE" ]; then
  echo "Existing creds file found. Overwrite? [y/N] "
  read -r ans
  [ "${ans:-}" = "y" ] || { echo "Aborted."; exit 0; }
fi

# Collect credentials (defaults in brackets; press Enter to accept).
read -r -p "Infisical API domain [$DEFAULT_DOMAIN]: " domain
domain="${domain:-$DEFAULT_DOMAIN}"
read -r -p "Machine Identity Client ID: " client_id
[ -n "$client_id" ] || { echo "Client ID is required."; exit 1; }
read -rs -p "Machine Identity Client Secret: " client_secret
echo ""
[ -n "$client_secret" ] || { echo "Client Secret is required."; exit 1; }
read -r -p "Project ID [$DEFAULT_PROJECT_ID]: " project_id
project_id="${project_id:-$DEFAULT_PROJECT_ID}"
read -r -p "Project slug [$DEFAULT_PROJECT_SLUG]: " project_slug
project_slug="${project_slug:-$DEFAULT_PROJECT_SLUG}"
read -r -p "Environment [$DEFAULT_ENV]: " env
env="${env:-$DEFAULT_ENV}"
read -r -p "Secret path [$DEFAULT_PATH]: " path
path="${path:-$DEFAULT_PATH}"

# Verify login BEFORE writing anything.
echo ""
echo "Verifying Universal Auth login..."
token=$(curl -fsS -X POST "$domain/v1/auth/universal-auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"clientId\":\"$client_id\",\"clientSecret\":\"$client_secret\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])") \
  || { echo "Login failed — check the client ID/secret and domain."; exit 1; }
echo "  OK — access token obtained."

echo "Verifying read access to project $project_id / $env / $path ..."
count=$(curl -fsS -X GET "$domain/v3/secrets/raw?workspaceId=$project_id&environment=$env&secretPath=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$path'))")&include_imports=false" \
  -H "Authorization: Bearer $token" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('secrets',[])))") \
  || { echo "Read failed — the identity may lack Read Secrets on this project/env."; exit 1; }
echo "  OK — readable secret count: $count"

# Write the creds file (0600).
mkdir -p "$(dirname "$CREDS_FILE")"
umask 077
cat > "$CREDS_FILE" <<EOF
# Infisical Machine Identity credentials — DO NOT COMMIT.
# Created by scripts/infisical-agent-setup.sh on $(date -u +%FT%TZ)
# perms: 0600. Rotate by re-running setup, or revoke the identity in the UI.
export INFISICAL_DOMAIN="$domain"
export INFISICAL_MACHINE_CLIENT_ID="$client_id"
export INFISICAL_MACHINE_CLIENT_SECRET="$client_secret"
export INFISICAL_PROJECT_ID="$project_id"
export INFISICAL_PROJECT_SLUG="$project_slug"
export INFISICAL_ENV="$env"
export INFISICAL_PATH="$path"
EOF
chmod 600 "$CREDS_FILE"
echo ""
echo "Creds written to $CREDS_FILE (mode 0600)."

echo ""
echo "Setup complete. Next steps:"
echo "  source scripts/infisical-agent.sh   # load INFISICAL_TOKEN + helpers"
echo "  infs secrets                        # list secrets"
echo "  infs get CLOUDFLARE_API_TOKEN       # print one secret's value"
echo ""
echo "Add this to your shell profile for automatic loading:"
echo "  [ -f \"$CREDS_FILE\" ] && source $(cd "$(dirname "$0")" && pwd)/infisical-agent.sh"