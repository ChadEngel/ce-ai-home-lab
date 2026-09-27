#!/usr/bin/env bash
# udm-rsyslog-update.sh — point UDM Pro's rsyslogd setting at our syslog receiver.
#
# Required env:
#   UDM_HOST          -- e.g. 192.168.250.1 (default), unifi.home, or
#                        setup.ui.com during first boot
#   UDM_ADMIN_USER    -- Infisical UDM_ADMIN_USER (default: fetched from Infisical)
#   UDM_ADMIN_PASS    -- Infisical UDM_ROOT_PASSWORD or UDM_SSH_PASS
#   RECEIVER_HOST     -- IP or DNS of the syslog receiver
#                        (default: 192.168.30.189 == caelx004.home)
#   RECEIVER_PORT     -- default 1514
#
# Uses the UniFi OS login API (cookie session) — the X-API-KEY integration
# token is controller-side and not what UniFi OS / Network 9+ expects for
# /api/s/default/rest/setting/rsyslogd on a freshly adopted controller.
#
# Behaviour:
#   1. POST /api/login -> cookie session
#   2. GET /api/s/default/rest/setting/rsyslogd -> current settings
#   3. Modify: enabled=true, ip=RECEIVER_HOST, port=RECEIVER_PORT
#   4. PUT /api/s/default/rest/setting/rsyslogd -> write back
#   5. Verify by GETting again

set -euo pipefail

RECEIVER_HOST="${RECEIVER_HOST:-192.168.30.189}"  # caelx004.home
RECEIVER_PORT="${RECEIVER_PORT:-1514}"
UDM_HOST="${UDM_HOST:-192.168.250.1}"

# Try Infisical for UDM creds if not set
if [ -z "${UDM_ADMIN_USER:-}" ] || [ -z "${UDM_ADMIN_PASS:-}" ]; then
    REPO="$(cd "$(dirname "$0")/../.." && pwd)"
    # shellcheck disable=SC1091
    source "$REPO/scripts/infisical-agent.sh" >/dev/null 2>&1 || true
    UDM_ADMIN_USER="${UDM_ADMIN_USER:-$(infs get UDM_ADMIN_USER 2>/dev/null || echo root)}"
    UDM_ADMIN_PASS="${UDM_ADMIN_PASS:-$(infs get UDM_ROOT_PASSWORD 2>/dev/null || infs get UDM_SSH_PASS 2>/dev/null)}"
fi
[ -n "$UDM_ADMIN_USER" ] || { echo "ERROR: UDM_ADMIN_USER not set" >&2; exit 1; }
[ -n "$UDM_ADMIN_PASS" ] || { echo "ERROR: UDM_ADMIN_PASS not set" >&2; exit 1; }

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

API="https://$UDM_HOST"
echo "==> UDM Pro rsyslog update"
echo "    UDM_HOST       = $UDM_HOST"
echo "    RECEIVER_HOST  = $RECEIVER_HOST"
echo "    RECEIVER_PORT  = $RECEIVER_PORT"
echo

# 1. login
echo "==> logging in to $UDM_HOST"
login_json=$(curl -sk -c "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$UDM_ADMIN_USER\",\"password\":\"$UDM_ADMIN_PASS\"}" \
    "$API/api/login")
echo "$login_json" | python3 -c "import sys,json; d=json.load(sys.stdin); ok = d if isinstance(d,bool) else d.get('meta',{}).get('rc')=='ok'; sys.exit(0 if ok else 1)" || { echo "ERROR: login failed: $login_json" >&2; exit 2; }

# 2. GET current rsyslogd setting
echo "==> GET /rest/setting/rsyslogd"
current=$(curl -sk -b "$COOKIE_JAR" "$API/api/s/default/rest/setting/rsyslogd")
echo "$current" | python3 -m json.tool | head -20

# 3. PUT new settings
echo "==> PUT /rest/setting/rsyslogd (ip=$RECEIVER_HOST port=$RECEIVER_PORT)"
new_body=$(echo "$current" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in ('_id', 'id', 'key'):
    d.pop(k, None)
d['enabled'] = True
d['ip'] = '$RECEIVER_HOST'
d['port'] = int('$RECEIVER_PORT')
print(json.dumps(d))
")
echo "    payload: $new_body"
result=$(curl -sk -b "$COOKIE_JAR" -X PUT \
    -H "Content-Type: application/json" \
    -d "$new_body" \
    "$API/api/s/default/rest/setting/rsyslogd")
echo "    result: $result"

# 4. verify
echo
echo "==> verifying"
curl -sk -b "$COOKIE_JAR" "$API/api/s/default/rest/setting/rsyslogd" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', [{}])[0]
print('  enabled:', d.get('enabled'))
print('  ip     :', d.get('ip'))
print('  port   :', d.get('port'))
print('  contents:', d.get('contents'))
"

echo
echo "==> done."
