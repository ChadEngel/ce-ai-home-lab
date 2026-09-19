#!/bin/bash
# Read-only verification of the Grafana alerting + dashboard state.
#
# Run from the repository root: ./scripts/verify-grafana.sh
#
# WHY THIS EXISTS
# ---------------
# Verifying Grafana state through the HTTP API is unreliable: `GET
# /api/v1/provisioning/alert-rules` returns `[]` identically for "never
# existed" and "was deleted", so a check that fails gives you no way to tell
# whether to re-run a deploy or go dig into the database. That ambiguity is
# what causes the re-run loop.
#
# This script instead:
#   1. makes ONE HTTP pass and reports HTTP status codes (not body greps),
#   2. reads Postgres for the deletion tombstones Grafana leaves behind
#      (`alert_rule_version` survives rule deletion; `resource_history`
#      records every create/update/delete),
#   3. diffs live state against the repo's source-of-truth files,
#   4. exits non-zero on drift.
#
# It NEVER writes. Safe to run any time, as often as you like.
#
# Exit codes: 0 = all good, 1 = drift/missing, 2 = could not determine state.

set -uo pipefail

NAMESPACE="ai"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ALERTS_DIR="$REPO_ROOT/scripts/grafana/alerts"
DASH_DIR="$REPO_ROOT/scripts/grafana/dashboards"
CM_NAME="grafana-dashboards-json"
GRAFANA="http://grafana:3000"

# The udm-thermal pod carries curl and can reach the Grafana Service.
CURL_POD="$(kubectl get pod -n "$NAMESPACE" -l app=udm-thermal \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$CURL_POD" ]; then
  echo "[✗] no curl pod (app=udm-thermal) found; cannot query Grafana" >&2
  exit 2
fi

GF_USER="$(kubectl get secret grafana-secrets -n "$NAMESPACE" -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d)"
GF_PASS="$(kubectl get secret grafana-secrets -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)"
if [ -z "$GF_USER" ] || [ -z "$GF_PASS" ]; then
  echo "[✗] could not read grafana-secrets" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0

# gf <path> <outfile> -> echoes the HTTP status code, writes body to outfile.
# Reports the status code rather than grepping the body: a 200 with an empty
# array is meaningfully different from a 404 or a 500.
gf() {
  local path="$1" out="$2" code
  code="$(kubectl exec -n "$NAMESPACE" "$CURL_POD" -- sh -c \
    "curl -s -o /tmp/verify-out.json -w '%{http_code}' -u '$GF_USER:$GF_PASS' '$GRAFANA$path'" 2>/dev/null)"
  kubectl exec -n "$NAMESPACE" "$CURL_POD" -- cat /tmp/verify-out.json > "$out" 2>/dev/null
  echo "$code"
}

echo "=============================================================="
echo " Grafana verification (read-only) — via $CURL_POD"
echo "=============================================================="

# ---------------------------------------------------------------- 1. health
echo ""
echo "── 1. Grafana health ─────────────────────────────────────────"
CODE="$(gf /api/health "$TMP/health.json")"
if [ "$CODE" = "200" ]; then
  python3 -c "
import json
d=json.load(open('$TMP/health.json'))
print('  [ok] version %s, database %s' % (d.get('version'), d.get('database')))
" 2>/dev/null || echo "  [ok] HTTP 200"
else
  echo "  [✗] /api/health -> HTTP $CODE"
  FAIL=1
fi

# ------------------------------------------------- 2. replicas / DB backend
echo ""
echo "── 2. Deployment shape ───────────────────────────────────────"
REPLICAS="$(kubectl get deploy grafana -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
DBTYPE="$(kubectl get deploy grafana -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GF_DATABASE_TYPE")].value}' 2>/dev/null)"
echo "  replicas: ${REPLICAS:-?}   database: ${DBTYPE:-sqlite(default)}"
if [ "${DBTYPE:-sqlite}" != "postgres" ] && [ "${REPLICAS:-1}" -gt 1 ] 2>/dev/null; then
  echo "  [✗] >1 replica with a non-Postgres DB — SQLite cannot take two writers"
  FAIL=1
else
  echo "  [ok] replica/DB combination is safe"
fi

# ------------------------------------------------------- 3. alert rules
echo ""
echo "── 3. Alert rules (live vs repo) ─────────────────────────────"
CODE="$(gf /api/v1/provisioning/alert-rules "$TMP/rules.json")"
if [ "$CODE" != "200" ]; then
  echo "  [✗] alert-rules -> HTTP $CODE"
  FAIL=1
else
  # Expected titles come from the repo rule files.
  EXPECTED="$TMP/expected.txt"
  : > "$EXPECTED"
  for f in "$ALERTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$f" >> "$EXPECTED"
  done
  sort -o "$EXPECTED" "$EXPECTED"

  python3 - "$TMP/rules.json" "$EXPECTED" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))
expected = [l.strip() for l in open(sys.argv[2]) if l.strip()]
live = sorted(r["title"] for r in rules)
print("  live: %d   expected: %d" % (len(live), len(expected)))
missing = [t for t in expected if t not in live]
extra = [t for t in live if t not in expected]
for t in live:
    print("    - %s" % t)
for t in missing:
    print("  [✗] MISSING: %s" % t)
for t in extra:
    print("  [!] not in repo: %s" % t)
sys.exit(1 if missing else 0)
PY
  [ $? -ne 0 ] && FAIL=1
fi

# ------------------------------------------- 4. contact point / policy
echo ""
echo "── 4. Notification routing ───────────────────────────────────"
CODE="$(gf /api/v1/provisioning/contact-points "$TMP/cp.json")"
if [ "$CODE" = "200" ] && grep -q '"pushover-bridge"' "$TMP/cp.json" 2>/dev/null; then
  echo "  [ok] contact point 'pushover-bridge' present"
else
  echo "  [✗] contact point 'pushover-bridge' missing (HTTP $CODE)"
  FAIL=1
fi
CODE="$(gf /api/v1/provisioning/policies "$TMP/pol.json")"
if [ "$CODE" = "200" ] && grep -q '"pushover-bridge"' "$TMP/pol.json" 2>/dev/null; then
  echo "  [ok] notification policy routes to 'pushover-bridge'"
else
  echo "  [✗] notification policy not routing to pushover-bridge (HTTP $CODE)"
  FAIL=1
fi

# -------------------------------------------------------- 5. dashboards
echo ""
echo "── 5. Dashboards (live vs repo + ConfigMap) ──────────────────"
CODE="$(gf '/api/search?type=dash-db' "$TMP/search.json")"
LIVE_TITLES="$TMP/live_titles.txt"
python3 -c "
import json
for d in json.load(open('$TMP/search.json')):
    print(d['title'])
" 2>/dev/null | sort > "$LIVE_TITLES"

# The ConfigMap is what the file provider actually mounts.
CM_KEYS="$TMP/cm_keys.txt"
kubectl get cm "$CM_NAME" -n "$NAMESPACE" -o jsonpath='{.data}' 2>/dev/null \
  | python3 -c "import json,sys;print('\n'.join(sorted(json.load(sys.stdin).keys())))" 2>/dev/null | sort > "$CM_KEYS"

LOCAL_KEYS="$TMP/local_keys.txt"
for f in "$DASH_DIR"/*.json; do [ -f "$f" ] && basename "$f"; done | sort > "$LOCAL_KEYS"

echo "  live dashboards: $(wc -l < "$LIVE_TITLES" | tr -d ' ')   local *.json: $(wc -l < "$LOCAL_KEYS" | tr -d ' ')   ConfigMap keys: $(wc -l < "$CM_KEYS" | tr -d ' ')"
sed 's/^/    - /' "$LIVE_TITLES"

# Every local *.json must be present in the ConfigMap.
MISSING_CM="$(comm -23 "$LOCAL_KEYS" "$CM_KEYS")"
if [ -n "$MISSING_CM" ]; then
  echo "  [✗] local dashboards absent from ConfigMap (file provider cannot see them):"
  echo "$MISSING_CM" | sed 's/^/      /'
  FAIL=1
else
  echo "  [ok] every local *.json is in the ConfigMap"
fi

# Warn about ConfigMap keys with no local file (drift; additive deploy preserves
# these, but they are invisible to the repo and can be lost on a --prune).
ORPHANS="$(comm -13 "$LOCAL_KEYS" "$CM_KEYS")"
if [ -n "$ORPHANS" ]; then
  echo "  [!] ConfigMap keys with no local *.json (drift — preserved, but untracked):"
  echo "$ORPHANS" | sed 's/^/      /'
fi

# ------------------------------------------------- 6. deletion tombstones
echo ""
echo "── 6. Postgres tombstone audit (what was deleted) ────────────"
PGPASS="$(kubectl get secret postgres-secrets -n "$NAMESPACE" -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)"
if [ -z "$PGPASS" ]; then
  echo "  [!] postgres-secrets unreadable — skipping DB audit"
else
  Q() { kubectl exec -n "$NAMESPACE" postgres-0 -- env PGPASSWORD="$PGPASS" \
        psql -U postgres -d grafana -tAc "$1" 2>/dev/null; }

  # alert_rule_version survives rule deletion and is the reliable record that a
  # rule once existed. Compare against the live count to spot silent deletions.
  LIVE_RULES="$(python3 -c "import json;print(len(json.load(open('$TMP/rules.json'))))" 2>/dev/null || echo '?')"
  HIST_RULES="$(Q "select count(distinct title) from alert_rule_version;")"
  echo "  rules live: $LIVE_RULES   distinct titles ever recorded: ${HIST_RULES:-?}"
  if [ -n "$HIST_RULES" ] && [ "$LIVE_RULES" != "?" ] && [ "$HIST_RULES" -gt "$LIVE_RULES" ] 2>/dev/null; then
    echo "  [!] more titles in history than live — a rule was deleted:"
    Q "select distinct title from alert_rule_version order by title;" | sed 's/^/      ever: /'
    echo "      (re-provision with: ./scripts/deploy-grafana-alerts.sh)"
  fi

  # Recent folder/rule deletions from the resource history.
  echo "  recent resource history (folders + dashboards):"
  Q "select resource||' '||name||' action='||action from resource_history where resource in ('folders','dashboards') order by resource_version desc limit 12;" \
    | sed 's/^/      /'
fi

# ---------------------------------------------------------------- verdict
echo ""
echo "=============================================================="
if [ "$FAIL" -eq 0 ]; then
  echo " [✅] Grafana state matches the repo"
  echo "=============================================================="
  exit 0
else
  echo " [✗] DRIFT DETECTED — see [✗] lines above"
  echo ""
  echo " To re-provision:"
  echo "   ./scripts/deploy-grafana-alerts.sh   # alert rules + routing"
  echo "   ./scripts/deploy-grafana.sh          # dashboards (additive)"
  echo "=============================================================="
  exit 1
fi
