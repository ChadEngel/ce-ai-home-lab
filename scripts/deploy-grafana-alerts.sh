#!/bin/bash
# Idempotently provision the Grafana alerting resources for this lab:
#   - the folders named in each rule file (e.g. "UDM Alerts",
#     "Infrastructure Alerts"),
#   - the "pushover-bridge" contact point (webhook -> pushover-bridge svc),
#   - the notification policy routing alerts to it (grouped by service),
#   - every alert rule defined in scripts/grafana/alerts/*.json.
#
# Each rule file is the source of truth for one rule (title, folder, data
# pipeline, labels, annotations). Add a file and re-run; it is upserted by
# title. Grafana file provisioning only covers rules (not contact points /
# policies), so this drives Grafana's provisioning HTTP API instead. It mirrors
# the other deploy-*.sh scripts.
#
# Run from the repository root: ./scripts/deploy-grafana-alerts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ALERTS_DIR="$REPO_ROOT/scripts/grafana/alerts"
NAMESPACE="ai"

GF_USER="$(kubectl get secret grafana-secrets -n "$NAMESPACE" -o jsonpath='{.data.admin-user}' | base64 -d)"
GF_PASS="$(kubectl get secret grafana-secrets -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d)"
GRAFANA="http://grafana:3000"
AUTH="$GF_USER:$GF_PASS"

# HTTP is issued by kubectl exec into a curl-capable pod (the udm-thermal pod
# carries curl; Grafana is reachable as http://grafana:3000 over the cluster
# network). Requires kubectl access to the 'ai' namespace.
CURL_POD="$(kubectl get pod -n "$NAMESPACE" -l app=udm-thermal --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$CURL_POD" ]; then
  echo "[✗] no curl pod found (app=udm-thermal). Is udm-thermal deployed?" >&2
  exit 1
fi

TMPDIR_L="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_L"' EXIT

# api <METHOD> <PATH> [body-file]   -> prints response body to stdout.
# `-i` is required so a request body piped on stdin reaches curl's --data @-.
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

# ensure_folder <name> -> prints the folder UID (creating it if absent).
ensure_folder() {
  local name="$1" uid
  fetch_folders() {
    kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
      "curl -s -X GET -u '$AUTH' $GRAFANA/api/folders" 2>/dev/null > "$TMPDIR_L/folders.json"
  }
  fetch_folders
  uid="$(python3 -c "
import json, sys
want = sys.argv[1]
for f in json.load(open(sys.argv[2])):
    if f.get('title') == want:
        print(f['uid']); break
" "$name" "$TMPDIR_L/folders.json")"
  if [ -z "$uid" ]; then
    echo "[ ] creating folder '$name'" >&2
    kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
      "curl -s -X POST -u '$AUTH' -H 'Content-Type: application/json' --data '{\"title\":\"$name\"}' $GRAFANA/api/folders" >/dev/null
    fetch_folders
    uid="$(python3 -c "
import json, sys
want = sys.argv[1]
for f in json.load(open(sys.argv[2])):
    if f.get('title') == want:
        print(f['uid']); break
" "$name" "$TMPDIR_L/folders.json")"
  fi
  echo "$uid"
}

echo "=== Grafana alerting provisioning (via $CURL_POD) ==="

# 1. Contact point "pushover-bridge" (webhook -> the bridge svc).
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

# 2. Notification policy -> pushover-bridge, grouped by grafana_folder +
#    alertname + service (so each service alerts separately).
echo "[ ] notification policy -> pushover-bridge (group by service)"
kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
  "curl -s -X PUT -u '$AUTH' -H 'Content-Type: application/json' \
   --data '{\"receiver\":\"pushover-bridge\",\"group_by\":[\"grafana_folder\",\"alertname\",\"service\"],\"group_wait\":\"30s\",\"group_interval\":\"5m\",\"repeat_interval\":\"4h\"}' \
   $GRAFANA/api/v1/provisioning/policies" >/dev/null

# 3. Upsert every alert rule defined in scripts/grafana/alerts/*.json.
RULE_COUNT=0
for RULE_FILE in "$ALERTS_DIR"/*.json; do
  [ -f "$RULE_FILE" ] || continue

  FOLDER_NAME="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("folder","Alerts"))' "$RULE_FILE")"
  FOLDER_UID="$(ensure_folder "$FOLDER_NAME")"
  if [ -z "$FOLDER_UID" ]; then
    echo "[⚠️] could not resolve folder '$FOLDER_NAME' for $RULE_FILE" >&2
    exit 1
  fi

  python3 - "$RULE_FILE" "$FOLDER_UID" <<'PYEOF' > "$TMPDIR_L/rule_payload.json"
import json, sys
rule = json.load(open(sys.argv[1]))
payload = {
    "title": rule["title"],
    "ruleGroup": rule["ruleGroup"],
    "folderUID": sys.argv[2],
    "condition": rule["condition"],
    "for": rule["for"],
    "noDataState": rule["noDataState"],
    "execErrState": rule.get("execErrState", "OK"),
    "data": rule["data"],
}
if "labels" in rule:
    payload["labels"] = rule["labels"]
if "annotations" in rule:
    payload["annotations"] = rule["annotations"]
print(json.dumps(payload))
PYEOF

  RULE_TITLE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$TMPDIR_L/rule_payload.json")"
  EXISTING="$(api GET /api/v1/provisioning/alert-rules)"
  printf '%s' "$EXISTING" > "$TMPDIR_L/rules.json"
  RULE_UID="$(python3 -c "
import json, sys
want = sys.argv[1]
for r in json.load(open(sys.argv[2])):
    if r.get('title') == want:
        print(r['uid']); break
" "$RULE_TITLE" "$TMPDIR_L/rules.json")"

  if [ -n "$RULE_UID" ]; then
    echo "  [ ] updating '$RULE_TITLE' ($FOLDER_NAME)"
    RESP="$(api PUT "/api/v1/provisioning/alert-rules/$RULE_UID" "$TMPDIR_L/rule_payload.json")"
  else
    echo "  [ ] creating '$RULE_TITLE' ($FOLDER_NAME)"
    RESP="$(api POST /api/v1/provisioning/alert-rules "$TMPDIR_L/rule_payload.json")"
  fi
  if ! echo "$RESP" | grep -q '"uid"'; then
    echo "[⚠️] upsert failed for '$RULE_TITLE'; API said: $RESP" >&2
    exit 1
  fi
  echo "      [ok] $RULE_TITLE"
  RULE_COUNT=$((RULE_COUNT + 1))
done

echo "[✅] provisioning complete: $RULE_COUNT alert rule(s) -> pushover-bridge"
