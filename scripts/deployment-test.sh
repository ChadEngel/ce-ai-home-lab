#!/bin/bash
#
# Deployment Test Script for ce-ai-home-lab
# Verifies all components are deployed and functioning correctly
#
# Usage: ./scripts/deployment-test.sh [namespace] [options]
#   namespace:   Target namespace (default: ai)
#   --verbose:   Enable detailed output
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Infrastructure unavailable (cluster not accessible)

set -u

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
NAMESPACE="ai"
VERBOSE="false"
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE="true" ;;
        -*) ;;  # ignore unknown flags
        *) NAMESPACE="$arg" ;;
    esac
done

START_TIME=$(date +%s)
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Helper functions
log() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    if [ "$VERBOSE" = "true" ]; then
        echo -e "${GREEN}✓${NC} ${1:-PASS}${2:+: $2}"
    fi
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}✗${NC} $1: $2"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${YELLOW}⚠${NC} $1: $2"
}

print_section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Check if kubectl is available
check_kubectl_available() {
    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}ERROR: kubectl is not installed${NC}"
        exit 2
    fi
    if ! kubectl cluster-info &>/dev/null; then
        echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster${NC}"
        exit 2
    fi
}

# Check if a pod is in the given phase
check_pod_running() {
    local pod_name="$1"
    local expected="${2:-Running}"
    local status
    status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" \
        --output=jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
    if [ "$status" = "$expected" ]; then
        pass "$pod_name is $expected"
        return 0
    fi
    fail "$pod_name" "Expected $expected but got $status"
    return 1
}

check_service_available() {
    local service_name="$1"
    if kubectl get svc "$service_name" -n "$NAMESPACE" &>/dev/null; then
        pass "$service_name exists"
    else
        fail "$service_name" "Service does not exist"
    fi
}

check_ingress_configured() {
    local ingress_name="$1"
    if ! kubectl get ingress "$ingress_name" -n "$NAMESPACE" &>/dev/null; then
        fail "$ingress_name" "Ingress does not exist"
        return 1
    fi
    pass "$ingress_name configured"
    if kubectl get ingress "$ingress_name" -n "$NAMESPACE" \
            --output=jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null | grep -q .; then
        pass "$ingress_name has loadBalancer"
    else
        warn "$ingress_name" "No load balancer status yet (may be delayed)"
    fi
}

check_storageclass() {
    local sc_name="$1"
    if ! kubectl get storageclass "$sc_name" &>/dev/null; then
        fail "$sc_name" "StorageClass does not exist"
        return
    fi
    pass "$sc_name exists"
    local is_default
    is_default=$(kubectl get storageclass "$sc_name" \
        -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)
    if [ "$is_default" = "true" ]; then
        pass "$sc_name is default storage class"
    fi
}

check_pvc() {
    local pvc_name="$1"
    local expected="${2:-Bound}"
    if ! kubectl get pvc "$pvc_name" -n "$NAMESPACE" &>/dev/null; then
        fail "$pvc_name" "PVC does not exist"
        return
    fi
    local status
    status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" \
        --output=jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
    if [ "$status" = "$expected" ]; then
        pass "$pvc_name is $expected"
    else
        fail "$pvc_name" "Expected $expected but got $status"
    fi
}

check_certificate() {
    local cert_name="$1"
    if ! kubectl get certificate "$cert_name" -n "$NAMESPACE" &>/dev/null; then
        fail "$cert_name" "Certificate does not exist"
        return
    fi
    local ready
    ready=$(kubectl get certificate "$cert_name" -n "$NAMESPACE" \
        --output=jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$ready" = "True" ]; then
        pass "$cert_name is issued"
    else
        warn "$cert_name" "Ready status: ${ready:-unknown}"
    fi
}

check_configmap() {
    local cm_name="$1"
    if kubectl get configmap "$cm_name" -n "$NAMESPACE" &>/dev/null; then
        pass "$cm_name exists"
    else
        warn "$cm_name" "ConfigMap does not exist (may be generated dynamically)"
    fi
}

check_secret_exists() {
    local secret_name="$1"
    if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
        pass "$secret_name exists"
    else
        warn "$secret_name" "Secret does not exist"
    fi
}

test_network_connectivity() {
    local host="$1"
    local port="${2:-}"
    if [ -n "$port" ]; then
        if timeout 5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            pass "$host:$port is reachable"
        else
            fail "$host:$port" "Not accessible"
        fi
    else
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            pass "$host is reachable"
        else
            warn "$host" "Network unreachable (may be expected for external hosts)"
        fi
    fi
}

# ============================================================================
# ACTUAL TESTS
# ============================================================================

print_section "CLUSTER CONNECTION"
check_kubectl_available

print_section "NAMESPACE VERIFICATION"
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    pass "$NAMESPACE namespace exists"
else
    fail "$NAMESPACE namespace" "Does not exist or not accessible"
fi

print_section "INFRASTRUCTURE COMPONENTS"
check_storageclass "nfs-client"

print_section "PODS"
for pod in $(kubectl get pods -n "$NAMESPACE" --output=jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    status=$(kubectl get pod "$pod" -n "$NAMESPACE" \
        --output=jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
    if [ "$status" = "Running" ] || [ "$status" = "Completed" ]; then
        pass "$pod is $status"
    else
        warn "$pod" "Status: $status"
    fi
done

print_section "SERVICES"
check_service_available "openwebui"
check_service_available "searxng-api"
check_service_available "bifrost-api"
check_service_available "infisical"
check_service_available "infisical-db"
check_service_available "grafana" 2>/dev/null || warn "grafana service" "May not be deployed"

print_section "INGRESSES"
check_ingress_configured "openwebui-ingress"
check_ingress_configured "searxng-ingress"
check_ingress_configured "bifrost-ingress"
check_ingress_configured "infisical-ingress" 2>/dev/null || warn "infisical-ingress" "May not be deployed"
check_ingress_configured "grafana-ingress" 2>/dev/null || warn "grafana-ingress" "May not be deployed"

print_section "CERTIFICATES"
check_certificate "openwebui-tls"
check_certificate "searxng-tls"
check_certificate "bifrost-tls"
check_certificate "infisical-ssl-certs" 2>/dev/null || warn "infisical-ssl-certs" "May not be issued yet"
check_certificate "grafana-tls" 2>/dev/null || warn "grafana-tls" "May not be issued yet"

print_section "SECRETS & CONFIGMAPS"
check_secret_exists "bifrost-secrets"
check_secret_exists "infisical-secrets"
check_secret_exists "infisical-db-creds"
check_secret_exists "grafana-secrets" 2>/dev/null || warn "grafana-secrets" "May not be deployed"
check_secret_exists "influxdb-secrets" 2>/dev/null || warn "influxdb-secrets" "May not be deployed"
check_configmap "searxng-settings"

print_section "INTERNAL ENDPOINTS (Bifrost & friends)"
# Probe via cluster DNS. We use a one-off busybox pod to execute the probe
# inside the cluster (your laptop cannot resolve cluster DNS).
# Each URL is checked for any HTTP response (2xx/3xx/4xx/5xx) — connectivity
# is what we care about, not success codes.
INTERNAL_URLS=(
    "http://bifrost-api.${NAMESPACE}.svc.cluster.local:8080/v1/models"
    "http://openwebui.${NAMESPACE}.svc.cluster.local:8080/"
    "http://searxng-api.${NAMESPACE}.svc.cluster.local:8080/"
    "http://infisical.${NAMESPACE}.svc.cluster.local:8080/api/status"
    "http://grafana.${NAMESPACE}.svc.cluster.local:3000/api/health"
)
# Build a probe script that runs all curl checks, one per line
PROBE_SCRIPT=""
for url in "${INTERNAL_URLS[@]}"; do
    PROBE_SCRIPT+="printf '%s ' '$url'; curl -s -o /dev/null -w '%{http_code}\n' -m 5 '$url' 2>/dev/null || echo 000; "
done
PROBE_OUTPUT=$(kubectl run -n "$NAMESPACE" probe-$RANDOM \
    --rm -i --restart=Never --image=curlimages/curl:latest \
    --quiet -- sh -c "$PROBE_SCRIPT" 2>/dev/null)
PROBE_EXIT=$?
if [ "$PROBE_EXIT" -ne 0 ] || [ -z "$PROBE_OUTPUT" ]; then
    warn "internal probe" "kubectl run probe failed (exit $PROBE_EXIT)"
else
    while IFS= read -r line; do
        # Each line: "URL HTTP_CODE" (e.g. "http://... 200")
        url="${line% *}"
        code="${line##* }"
        case "$code" in
            000) warn "$url" "Unreachable" ;;
            2*|3*|4*|5*) pass "$url responded with HTTP $code" ;;
            *) warn "$url" "Unexpected response: $code" ;;
        esac
    done <<< "$PROBE_OUTPUT"
fi

print_section "STORAGE VERIFICATION"
# Check if NFS server is reachable from this environment
if command -v showmount &>/dev/null; then
    if showmount -e 192.168.30.121 &>/dev/null; then
        pass "NFS server 192.168.30.121 is exporting"
    else
        warn "NFS server" "showmount -e 192.168.30.121 failed"
    fi
else
    warn "showmount" "Command not available; skipping NFS export check"
fi

# Summary
TOTAL_TESTS=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

print_section "TEST SUMMARY"
echo ""
echo "Total tests run:  $TOTAL_TESTS"
echo -e "${GREEN}Passed:          $PASS_COUNT${NC}"
echo -e "${RED}Failed:          $FAIL_COUNT${NC}"
echo -e "${YELLOW}Warnings:        $WARN_COUNT${NC}"
echo "Duration:         ${DURATION}s"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}═══════════════════════════════════${NC}"
    echo -e "${RED}   DEPLOYMENT TEST FAILED          ${NC}"
    echo -e "${RED}═══════════════════════════════════${NC}"
    exit 1
fi
echo -e "${GREEN}═══════════════════════════════════${NC}"
echo -e "${GREEN}   DEPLOYMENT TEST PASSED          ${NC}"
echo -e "${GREEN}═══════════════════════════════════${NC}"
exit 0
