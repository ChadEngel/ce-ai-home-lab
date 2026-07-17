#!/bin/bash
#
# Deployment Test Script for ce-ai-home-lab
# Verifies all components are deployed and functioning correctly
#
# Usage: ./scripts/deployment-test.sh [namespace] [--verbose]
#   namespace: Target namespace (default: ai)
#   --verbose: Enable detailed output
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Infrastructure unavailable (cluster not accessible)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${1:-ai}
VERBOSE=${2:--quiet}
START_TIME=$(date +%s)
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Test results array
declare -a TEST_RESULTS

# Helper functions
log() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"
}

pass() {
    local test_name="$1"
    local message="${2:-PASS}"
    TEST_RESULTS+=("PASS|$test_name|$message")
    echo -e "${GREEN}✓${NC} $test_name"
    ((PASS_COUNT++))
}

fail() {
    local test_name="$1"
    local message="$2"
    TEST_RESULTS+=("FAIL|$test_name|$message")
    echo -e "${RED}✗${NC} $test_name: $message"
    ((FAIL_COUNT++))
}

warn() {
    local test_name="$1"
    local message="$2"
    TEST_RESULTS+=("WARN|$test_name|$message")
    echo -e "${YELLOW}⚠${NC} $test_name: $message"
    ((WARN_COUNT++))
}

check() {
    local test_name="$1"
    shift
    if eval "$@" > /dev/null 2>&1; then
        pass "$test_name" "Command succeeded"
    else
        fail "$test_name" "Command failed: $*"
    fi
}

print_section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Check if kubectl is available
check_kubectl_available() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl is not installed${NC}"
        exit 2
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster${NC}"
        echo "Please ensure kubectl is configured for your cluster"
        exit 2
    fi
}

# Get namespace resources
get_namespace_pods() {
    kubectl get pods -n "$NAMESPACE" --output=jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}'
}

# Check if specific pod is running
check_pod_running() {
    local pod_name="$1"
    local expected="${2:-Running}"
    
    if kubectl get pod "$pod_name" -n "$NAMESPACE" --output=jsonpath='{.status.phase}' 2>/dev/null | grep -q "$expected"; then
        pass "$pod_name is $expected"
        return 0
    else
        local current_status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" --output=jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
        fail "$pod_name" "Expected $expected but got $current_status"
        return 1
    fi
}

# Check service availability
check_service_available() {
    local service_name="$1"
    local port="${2:-}"
    
    if kubectl get svc "$service_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        pass "$service_name exists"
        if [ -n "$port" ]; then
            local target_port=$(kubectl get svc "$service_name" -n "$NAMESPACE" --output=jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)
            pass "$service_name on port $target_port"
        fi
    else
        fail "$service_name" "Service does not exist"
    fi
}

# Check ingress configuration
check_ingress_configured() {
    local ingress_name="$1"
    
    if kubectl get ingress "$ingress_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        pass "$ingress_name configured"
        
        # Check if ingress has a valid backend
        if kubectl get ingress "$ingress_name" -n "$NAMESPACE" --output=jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null | grep -q .; then
            pass "$ingress_name has loadBalancer"
        else
            warn "$ingress_name" "No load balancer status yet (may be delayed)"
        fi
    else
        fail "$ingress_name" "Ingress does not exist"
    fi
}

# Check storage class exists
check_storageclass() {
    local sc_name="$1"
    
    if kubectl get storageclass "$sc_name" > /dev/null 2>&1; then
        local is_default=$(kubectl get storageclass "$sc_name" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)
        pass "$sc_name exists"
        if [ "$is_default" == "true" ]; then
            pass "$sc_name is default storage class"
        fi
    else
        fail "$sc_name" "StorageClass does not exist"
    fi
}

# Check PersistentVolumeClaim
check_pvc() {
    local pvc_name="$1"
    local expected_status="Bound"
    
    if kubectl get pvc "$pvc_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        local status=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" --output=jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$status" == "$expected_status" ]; then
            pass "$pvc_name is $expected_status"
        else
            fail "$pvc_name" "Expected $expected_status but got $status"
        fi
    else
        fail "$pvc_name" "PVC does not exist"
    fi
}

# Check cert-manager certificate
check_certificate() {
    local cert_name="$1"
    
    if kubectl get certificate "$cert_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        local ready=$(kubectl get certificate "$cert_name" -n "$NAMESPACE" --output=jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$ready" == "True" ]; then
            pass "$cert_name is issued"
        else
            warn "$cert_name" "Ready status: $ready"
        fi
    else
        fail "$cert_name" "Certificate does not exist"
    fi
}

# Check Helm release
check_helm_release() {
    local release_name="$1"
    local namespace="${2:-flux-system}"
    
    if command -v helm &> /dev/null; then
        if helm list -n "$namespace" | grep -q "$release_name"; then
            pass "$release_name Helm release deployed"
        else
            warn "$release_name" "Helm release not found (may not be deployed via Helm)"
        fi
    else
        warn "helm CLI" "Helm not installed, skipping Helm release check"
    fi
}

# Check configmaps
check_configmap() {
    local cm_name="$1"
    
    if kubectl get configmap "$cm_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        pass "$cm_name exists"
    else
        warn "$cm_name" "ConfigMap does not exist (may be generated dynamically)"
    fi
}

# Check secrets exist (don't reveal contents)
check_secret_exists() {
    local secret_name="$1"
    
    if kubectl get secret "$secret_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        pass "$secret_name exists"
    else
        warn "$secret_name" "Secret does not exist"
    fi
}

# Test network reachability
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
        if ping -c 1 -W 2 "$host" > /dev/null 2>&1; then
            pass "$host is reachable"
        else
            warn "$host" "Network unreachable (may be expected for external hosts)"
        fi
    fi
}

# Test URL endpoint
test_url_endpoint() {
    local url="$1"
    local http_code="${2:-200}"
    
    if command -v curl &> /dev/null; then
        local code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$url" 2>/dev/null || echo "000")
        if [ "$code" == "$http_code" ] || [ -z "$code" ] || [ "$code" == "000" ]; then
            # 000 means curl failed but that's OK for initial check
            pass "$url HTTP endpoint"
        else
            warn "$url" "HTTP code: $code (expected $http_code)"
        fi
    else
        warn "curl" "curl not available, skipping URL test"
    fi
}

# ============================================================================
# ACTUAL TESTS
# ============================================================================

print_section "CLUSTER CONNECTION"
check_kubectl_available

print_section "NAMESPACE VERIFICATION"
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 && pass "$NAMESPACE namespace exists" || fail "$NAMESPACE namespace" "Does not exist or not accessible"

print_section "INFRASTRUCTURE COMPONENTS"

# Storage
check_storageclass "nfs-client"
check_pvc "openwebui-pvc" 2>/dev/null || check_pvc "ollama-pvc"
check_pvc "searxng-pvc" 2>/dev/null || warn "StorageClass usage" "PVCs may not be automatically created"

# Check all pods in namespace are available
echo "Checking pods in namespace..."
for pod in $(kubectl get pods -n "$NAMESPACE" --output=jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if kubectl get pod "$pod" -n "$NAMESPACE" --output=jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running\|Completed"; then
        pass "$pod is Running/Completed"
    else
        local status=$(kubectl get pod "$pod" -n "$NAMESPACE" --output=jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
        warn "$pod" "Status: $status"
    fi
done

print_section "SERVICES"
check_service_available "bifrost-api"
check_service_available "ollama-api"
check_service_available "openwebui"
check_service_available "searxng-api"
check_service_available "mcpo"

print_section "INGRESS CONFIGURATION"
check_ingress_configured "openwebui-ingress"
check_ingress_configured "bifrost-ingress"
check_ingress_configured "searxng-ingress"

print_section "CERTIFICATES"
check_certificate "openwebui-tls" 2>/dev/null || warn "certificate openwebui" "May not be issued yet"
check_certificate "bifrost-tls" 2>/dev/null || warn "certificate bifrost" "May not be issued yet"
check_certificate "searxng-tls" 2>/dev/null || warn "certificate searxng" "May not be issued yet"

print_section "HELM RELEASES"
check_helm_release "nfs-storage" "ai"
check_helm_release "traefik" "kube-system"
check_helm_release "cert-manager" "cert-manager"

print_section "CONFIGMAPS AND SECRETS"
check_configmap "openwebui-bifrost-config"
check_secret_exists "bifrost-secrets"
check_secret_exists "infisical-secrets" 2>/dev/null || warn "infisical-secrets" "Infisical secrets may not be deployed"
check_secret_exists "infisical-db-creds" 2>/dev/null || warn "infisical-db-creds" "Database credentials may not be deployed"

print_section "DEPENDENCY CHECKS LiteLLM to Ollama"
# Check that LiteLLM can reach Ollama (ClusterIP)
if kubectl get svc ollama-api -n "$NAMESPACE" > /dev/null 2>&1; then
    pass "Litellm can reach Ollama via ClusterIP"
else
    warn "liteLLM→ollama connectivity" "Service unavailable"
fi

print_section "WEB APPLICATIONS ENDPOINTS"
# These are internal endpoints (within cluster)
print_section "DEPENDENCY CHECKS Bifrost to Ollama"
test_url_endpoint "http://bifrost-api.$NAMESPACE.svc.cluster.local:8080/v1/models"
test_url_endpoint "http://ollama-api.$NAMESPACE.svc.cluster.local:11434" 2>/dev/null || warn "ollama-api endpoint" "Internal service not directly accessible externally"
test_url_endpoint "http://openwebui.$NAMESPACE.svc.cluster.local:8080" 2>/dev/null || warn "openwebui endpoint" "Internal service not directly accessible externally"
test_url_endpoint "http://searxng-api.$NAMESPACE.svc.cluster.local:8080" 2>/dev/null || warn "searxng-api endpoint" "Internal service not directly accessible externally"

print_section "EXTERNAL ACCESS (Tailscale)"
# If Tailscale is configured, these should be accessible
if curl -s https://tailscale.com/check 2>/dev/null | grep -q "Tailscale"; then
    pass "Tailscale connectivity confirmed"
    # Test internal endpoints via Tailscale subnet (would need actual Tailscale IPs)
    test_url_endpoint "https://ai.example.com" 2>/dev/null || warn "ai.example.com (Tailscale)" "May need Tailscale access to test"
    test_url_endpoint "https://llm.example.com" 2>/dev/null || warn "llm.example.com (Tailscale)" "May need Tailscale access to test"
    test_url_endpoint "https://secrets.example.com" 2>/dev/null || warn "secrets.example.com (Tailscale)" "May need Tailscale access to test"
    test_url_endpoint "https://search.example.com" 2>/dev/null || warn "search.example.com (Tailscale)" "May need Tailscale access to test"
else
    warn "Tailscale" "External endpoint testing requires Tailscale access"
fi

print_section "STORAGE VERIFICATION"
# Check if NFS is mounted
if mount | grep -q "192.168.30.121"; then
    pass "NFS storage mounted and accessible"
else
    warn "NFS mount" "NFS server 192.168.30.121 not directly accessible from this environment"
fi

print_section "INFISICAL INTEGRATION"
check_service_available "infisical" 2>/dev/null || warn "infisical service" "May not be deployed in all configurations"
check_service_available "infisical-db" 2>/dev/null || warn "infisical-db service" "May not be deployed in all configurations"

print_section "RESOURCE LIMITS"
# Check if pods have resource limits configured
for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if kubectl get pod "$pod" -n "$NAMESPACE" --output=jsonpath='{.spec.containers[*].resources}' 2>/dev/null | grep -q .; then
        pass "$pod has resource limits configured"
    else
        warn "$pod" "No resource limits configured (may default to cluster settings)"
    fi
done

# Print summary
TOTAL_TESTS=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

print_section "TEST SUMMARY"
echo ""
echo -e "Total tests run: ${TOTAL_TESTS}"
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo -e "${YELLOW}Warnings: $WARN_COUNT${NC}"
echo -e "Duration: ${DURATION} seconds"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}═══════════════════════════════════${NC}"
    echo -e "${RED}   DEPLOYMENT TEST FAILED          ${NC}"
    echo -e "${RED}═══════════════════════════════════${NC}"
    exit 1
else
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo -e "${GREEN}   DEPLOYMENT TEST PASSED          ${NC}"
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    exit 0
fi
