#!/bin/bash
# Idempotently provision the Grafana alerting resources for the UDM SoC thermal
# alert: the "UDM Alerts" folder, the "pushover-bridge" contact point (webhook
# -> pushover-bridge svc), the notification policy routing alerts there, and the
# "UDM SoC temperature high" alert rule (SoC >= 90C for 1 minute).
#
# Source of truth for the rule body:
#   scripts/grafana/alerts/udm-soc-high.json
#
# Why a script and not Grafana file provisioning: Grafana file-provisions alert
# RULES cleanly, but contact points and notification policies do not have
# reliable file provisioning. This drives Grafana's provisioning HTTP API (the
# same API used when you build rules in the UI) so all four resources are
# enforced together, idempotently. It mirrors the other deploy-*.sh scripts.
#
# HTTP is issued by kubectl exec into a curl-capable pod in the same cluster
# (the udm-thermal pod carries curl; Grafana is reachable as http://grafana:3000
# over the cluster network). Requires kubectl access to the 'ai' namespace.
#
# Run from the repository root: ./scripts/deploy-grafana-alerts.sh
# Re-run any time you edit scripts/grafana/alerts/udm-soc-high.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RULE_FILE="$REPO_ROOT/scripts/grafana/alerts/udm-soc-high.json"
NAMESPACE="ai"

GF_USER="$(kubectl get secret grafana-secrets -n "$NAMESPACE" -o jsonpath='{.data.admin-user}' | base64 -d)"
GF_PASS="$(kubectl get secret grafana-secrets -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d)"
GRAFANA="http://grafana:3000"
AUTH="$GF_USER:$GF_PASS"

# Pod we exec curl from (must be Running and carry curl).
CURL_POD_SELECTOR="app=udm-thermal"
CURL_POD="$(kubectl get pod -n "$NAMESPACE" -l "$CURL_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$CURL_POD" ]; then
  echo "[✗] no curl pod found (selector '$CURL_POD_SELECTOR'). Is udm-thermal deployed?" >&2
  exit 1
fi

# api <METHOD> <PATH> [body-file]   -> prints response body to stdout
# NOTE: body transmission needs `-i` on kubectl exec so stdin is forwarded to
# curl's `--data @-`. Without `-i` the pipe is empty and Grafana sees an
# (empty) body with no folderUID.
api() {
  local method="$1" path="$2" body_file="${3:-}"
  if [ -n "$body_file" ]; then
    kubectl exec -i -n "$NAMESPACE" "$CURL_POD" -- sh -c \
      "curl -s -X $method -u '$AUTH' -H 'Content-Type: application/json' --data @- $GRAFANA$path" < "$body_file"
  else
    kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
      "curl -s -X $method -u '$AUTH' $GRAFANA$path"
  fi
}

echo "=== Grafana alerting provisioning (via $CURL_POD) ==="

# 1. Ensure folder "UDM Alerts" exists. Fetch to a temp file and parse from the
#    file — piping the kubectl exec output through python in a command
#    substitution was unreliable (stdout mangling), so we read from disk.
create_folder() {
  kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
    "curl -s -X POST -u '$AUTH' -H 'Content-Type: application/json' --data '{\"title\":\"UDM Alerts\"}' $GRAFANA/api/folders" >/dev/null
}
TMPDIR_L="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_L"' EXIT
kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
  "curl -s -X GET -u '$AUTH' $GRAFANA/api/folders" 2>/dev/null > "$TMPDIR_L/folders.json"
if ! grep -q '"UDM Alerts"' "$TMPDIR_L/folders.json"; then
  echo "[ ] creating folder 'UDM Alerts'"
  create_folder
  kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
    "curl -s -X GET -u '$AUTH' $GRAFANA/api/folders" 2>/dev/null > "$TMPDIR_L/folders.json"
fi
FOLDER_UID="$(python3 -c "
import json
for f in json.load(open('$TMPDIR_L/folders.json')):
    if f.get('title') == 'UDM Alerts':
        print(f['uid']); break
")"
if [ -z "$FOLDER_UID" ]; then
  echo "[⚠️] could not determine UDM Alerts folder uid" >&2
  exit 1
fi
echo "[ok] folder 'UDM Alerts' uid=$FOLDER_UID"

# 2. Ensure contact point "pushover-bridge" exists.
CP="$(api GET /api/v1/provisioning/contact-points)"
if ! echo "$CP" | grep -q '"name":"pushover-bridge"'; then
  echo "[ ] creating contact point 'pushover-bridge'"
  kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
    "curl -s -X POST -u '$AUTH' -H 'Content-Type: application/json' \
     --data '{\"name\":\"pushover-bridge\",\"type\":\"webhook\",\"settings\":{\"url\":\"http://pushover-bridge:8080/\",\"httpMethod\":\"POST\"}}' \
     $GRAFANA/api/v1/provisioning/contact-points" >/dev/null
else
  echo "[ok] contact point 'pushover-bridge' present"
fi

# 3. Notification policy -> pushover-bridge.
echo "[ ] notification policy -> pushover-bridge"
kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
  "curl -s -X PUT -u '$AUTH' -H 'Content-Type: application/json' \
   --data '{\"receiver\":\"pushover-bridge\",\"group_by\":[\"grafana_folder\",\"alertname\"],\"group_wait\":\"30s\",\"group_interval\":\"5m\",\"repeat_interval\":\"4h\"}' \
   $GRAFANA/api/v1/provisioning/policies" >/dev/null

# 4. Upsert the alert rule (by title) from scripts/grafana/alerts/udm-soc-high.json.
python3 - "$RULE_FILE" "$FOLDER_UID" <<'PYEOF'
import json, sys
rule = json.load(open(sys.argv[1]))
uid = sys.argv[2]
json.dump({
    "title": rule["title"],
    "ruleGroup": rule["ruleGroup"],
    "folderUID": uid,
    "condition": rule["condition"],
    "for": rule["for"],
    "noDataState": rule["noDataState"],
    "execErrState": rule["execErrState"],
    "data": rule["data"],
}, open("/tmp/udm_rule_payload.json", "w"))
PYEOF

EXISTING="$(api GET /api/v1/provisioning/alert-rules)"
echo "$EXISTING" > "$TMPDIR_L/rules.json"
RULE_UID="$(python3 -c "
import json
for r in json.load(open('$TMPDIR_L/rules.json')):
    if r.get('title') == 'UDM SoC temperature high':
        print(r['uid']); break
")"
if [ -n "$RULE_UID" ]; then
  echo "[ ] updating rule '$RULE_UID'"
  RESP="$(api PUT "/api/v1/provisioning/alert-rules/$RULE_UID" /tmp/udm_rule_payload.json)"
else
  echo "[ ] creating rule"
  RESP="$(api POST /api/v1/provisioning/alert-rules /tmp/udm_rule_payload.json)"
fi
rm -f /tmp/udm_rule_payload.json
# The provisioning API returns the stored rule JSON on success; an error comes
# back as an object with a "message". Verify we got a real rule (has a "uid").
if ! echo "$RESP" | grep -q '"uid"'; then
  echo "[⚠️] rule upsert did not return a uid; API said: $RESP" >&2
  exit 1
fi
echo "[✅] rule upserted: $(echo "$RESP" | grep -o '"title":"[^"]*"' | head -1)"

echo "[✅] provisioning complete: 'UDM SoC temperature high' (SoC >= 90C for 1m) -> pushover"
