#!/usr/bin/env bash
# infisical-agent.sh — sourced helper for non-human (Machine Identity) access
# to the self-hosted Infisical instance at https://secrets.caehomelab.com.
#
# It reads the Machine Identity credentials from a protected file, logs in
# via Universal Auth, caches the resulting access token, and exports
# INFISICAL_TOKEN + INFISICAL_DOMAIN so the `infisical` CLI "just works":
#
#     source scripts/infisical-agent.sh
#     infisical secrets --projectId "$INFISICAL_PROJECT_ID" --env prod --path /
#
# Convenience wrappers (defined below when sourced):
#     infs secrets [args...]   # infisical secrets, scoped to the homelab project/env/path
#     infs get  <KEY>          # print a single secret's value
#     infs set  <KEY>=<value>  # create/update a secret
#     infs del  <KEY>          # delete a secret
#     infs api  <method> <path> [json-body]   # raw Infisical API call (Bearer auth)
#
# Creds file (created by scripts/infisical-agent-setup.sh, mode 0600):
#     ~/.config/ce-ai-lab/infisical-agent.env   (override: $INFISICAL_AGENT_CREDS)
#       INFISICAL_DOMAIN=https://secrets.caehomelab.com/api
#       INFISICAL_MACHINE_CLIENT_ID=...
#       INFISICAL_MACHINE_CLIENT_SECRET=...
#       INFISICAL_PROJECT_ID=c8c51c11-2b4e-46d7-a97a-3e220ea59f7f
#       INFISICAL_PROJECT_SLUG=caehomelab-v1q6
#       INFISICAL_ENV=prod
#       INFISICAL_PATH=/
#
# Token cache (mode 0600): ~/.cache/ce-ai-lab/infisical-token
# (override: $INFISICAL_AGENT_TOKEN_CACHE). Refreshed when older than
# $INFISICAL_AGENT_TOKEN_TTL_S (default 86400 = 1 day; the token itself is
# valid 30 days, so this is a conservative refresh).

# Guard against being sourced multiple times.
if [ "${_INFISICAL_AGENT_SOURCED:-0}" = "1" ]; then return 0 2>/dev/null || true; fi
_INFISICAL_AGENT_SOURCED=1

infisical_agent__creds_file() {
  printf '%s\n' "${INFISICAL_AGENT_CREDS:-$HOME/.config/ce-ai-lab/infisical-agent.env}"
}
infisical_agent__token_cache() {
  printf '%s\n' "${INFISICAL_AGENT_TOKEN_CACHE:-$HOME/.cache/ce-ai-lab/infisical-token}"
}
infisical_agent__ttl() {
  printf '%s\n' "${INFISICAL_AGENT_TTL_S:-86400}"
}

# Load creds (fail loudly if missing — run infisical-agent-setup.sh first).
infisical_agent__load_creds() {
  local f; f="$(infisical_agent__creds_file)"
  if [ ! -f "$f" ]; then
    echo "infisical-agent: creds file not found: $f" >&2
    echo "  Run: ./scripts/infisical-agent-setup.sh" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "$f"
  INFISICAL_DOMAIN="${INFISICAL_DOMAIN:-https://secrets.caehomelab.com/api}"
  INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-c8c51c11-2b4e-46d7-a97a-3e220ea59f7f}"
  INFISICAL_ENV="${INFISICAL_ENV:-prod}"
  INFISICAL_PATH="${INFISICAL_PATH:-/}"
  export INFISICAL_DOMAIN INFISICAL_PROJECT_ID INFISICAL_ENV INFISICAL_PATH
}

# Log in via Universal Auth and print a fresh access token.
infisical_agent__login() {
  curl -fsS -X POST "$INFISICAL_DOMAIN/v1/auth/universal-auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\":\"$INFISICAL_MACHINE_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_MACHINE_CLIENT_SECRET\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])"
}

# Ensure a non-stale token is cached and exported. Returns the token on stdout.
infisical_agent_token() {
  infisical_agent__load_creds || return 1
  local cache ttl now mtime age token
  cache="$(infisical_agent__token_cache)"; ttl="$(infisical_agent__ttl)"; now=$(date +%s)
  if [ -f "$cache" ]; then mtime=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)
    case "$mtime" in ''|*[!0-9]*) mtime=0;; esac   # guard against non-numeric garbage
    age=$(( now - mtime ))
  else mtime=0; age=$(( now + 1 )); fi
  if [ "$age" -gt "$ttl" ] || [ ! -s "$cache" ]; then
    token="$(infisical_agent__login)" || { echo "infisical-agent: login failed" >&2; return 1; }
    mkdir -p "$(dirname "$cache")"; (umask 077; printf '%s' "$token" > "$cache")
  else
    token="$(cat "$cache")"
  fi
  export INFISICAL_TOKEN="$token"
  printf '%s\n' "$token"
}

# Raw Infisical API call with Bearer auth:
#   infs api GET /v3/secrets/raw?workspaceId=...&environment=prod&secretPath=/
infisical_api() {
  [ $# -ge 2 ] || { echo "usage: infs api <METHOD> <PATH> [JSON_BODY]" >&2; return 1; }
  local method="$1" path="$2" body="${3:-}" token
  token="$(infisical_agent_token)" || return 1
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$INFISICAL_DOMAIN$path" -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$method" "$INFISICAL_DOMAIN$path" -H "Authorization: Bearer $token"
  fi
}

# Convenience wrapper around `infisical` scoped to the homelab project/env/path.
infs() {
  infisical_agent_token >/dev/null || return 1
  case "${1:-}" in
    secrets) shift; infisical secrets --domain "$INFISICAL_DOMAIN" --projectId "$INFISICAL_PROJECT_ID" \
                --env "$INFISICAL_ENV" --path "$INFISICAL_PATH" "$@" ;;
    get)  local k="${2:-}"; [ -n "$k" ] || { echo "usage: infs get <KEY>" >&2; return 2; }
          local _p; _p=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$INFISICAL_PATH'))")
          infisical_api GET "/v3/secrets/raw?workspaceId=$INFISICAL_PROJECT_ID&environment=$INFISICAL_ENV&secretPath=$_p&include_imports=false" \
            | python3 -c "import sys,json; d=json.load(sys.stdin).get('secrets',[]); \
            m=[x for x in d if x['secretKey']=='$k']; \
            print(m[0]['secretValue']) if m else (sys.stderr.write('not found: $k\n'), sys.exit(1))" ;;
    set)  local kv="${2:-}"; [ -n "$kv" ] || { echo "usage: infs set <KEY>=<VALUE>" >&2; return 2; }
          infisical secrets set --silent --domain "$INFISICAL_DOMAIN" --token "$INFISICAL_TOKEN" \
            --projectId "$INFISICAL_PROJECT_ID" --env "$INFISICAL_ENV" --path "$INFISICAL_PATH" "$kv" ;;
    del)  local k="${2:-}"; [ -n "$k" ] || { echo "usage: infs del <KEY>" >&2; return 2; }
          infisical secrets delete --silent --domain "$INFISICAL_DOMAIN" --token "$INFISICAL_TOKEN" \
            --projectId "$INFISICAL_PROJECT_ID" --env "$INFISICAL_ENV" --path "$INFISICAL_PATH" --type shared "$k" ;;
    ssh-key)  # Materialize the agent's SSH private key from Infisical.
              #   infs ssh-key [path]   # default ~/.ssh/homelab-agent-util-server
              # The canonical key lives in Infisical secret UTIL_SERVER_SSH_PRIVATE_KEY
              # (base64). This fetches, decodes, and writes it (0600). Re-run after a
              # rotation or on a fresh host. Authorize the matching public key on the
              # target server's ~/.ssh/authorized_keys.
              local out="${2:-$HOME/.ssh/homelab-agent-util-server}"
              local b64
              b64="$(infs get UTIL_SERVER_SSH_PRIVATE_KEY)" || {
                echo "infs ssh-key: could not fetch UTIL_SERVER_SSH_PRIVATE_KEY from Infisical" >&2; return 1; }
              [ -n "$(printf '%s' "$b64" | tr -d ' \n')" ] || {
                echo "infs ssh-key: UTIL_SERVER_SSH_PRIVATE_KEY is empty" >&2; return 1; }
              mkdir -p "$(dirname "$out")"
              printf '%s' "$b64" | base64 -d > "$out"
              chmod 600 "$out"
              if ssh-keygen -l -f "$out" >/dev/null 2>&1; then
                echo "infs ssh-key: wrote $out (0600) — $(ssh-keygen -l -f "$out" 2>&1)" >&2
              else
                echo "infs ssh-key: WARNING — $out is not a valid key" >&2; return 1; fi ;;
    api)  shift; infisical_api "$@" ;;
    *)    echo "usage: infs {secrets|get|set|del|ssh-key|api} ..." >&2; return 2 ;;
  esac
}

# When sourced, eagerly load creds + token so the env is ready.
infisical_agent_token >/dev/null 2>&1 || true