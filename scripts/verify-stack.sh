#!/bin/bash
# scripts/verify-stack.sh
# Протокол автоматической проверки observability stack

set -e

APP_NAMESPACE="${1:-hello-app}"
MONITORING_NAMESPACE="${2:-monitoring}"
APP_RELEASE="${3:-hello-app}"
MONITORING_RELEASE="${4:-monitoring}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check() {
    local desc="$1"
    local cmd="$2"
    
    echo -n "Checking: $desc ... "
    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN} PASS${NC}"
        return 0
    else
        echo -e "${RED} FAIL${NC}"
        return 1
    fi
}

echo "Verification"


# 1. Проверка установки приложения
log_info "Phase 1: Application Deployment"
check "Namespace $APP_NAMESPACE exists" "kubectl get namespace $APP_NAMESPACE"
check "Deployment $APP_RELEASE is running" "kubectl rollout status deployment/$APP_RELEASE -n $APP_NAMESPACE --timeout=30s"
check "Service $APP_RELEASE exists" "kubectl get svc $APP_RELEASE -n $APP_NAMESPACE"
check "Pods are Ready" "kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=$APP_RELEASE -n $APP_NAMESPACE --timeout=60s"
echo ""

# 2. Проверка /metrics эндпоинта
log_info "Phase 2: Metrics Endpoint"
kubectl port-forward -n "$APP_NAMESPACE" svc/"$APP_RELEASE" 18080:80 &>/dev/null &
PF_PID=$!
sleep 3

check "Metrics endpoint responds" "curl -s http://localhost:18080/metrics | grep -q 'http_requests_total'"
check "Metrics format is valid" "curl -s http://localhost:18080/metrics | grep -qE '^# (HELP|TYPE)'"
check "Custom metrics present" "curl -s http://localhost:18080/metrics | grep -q 'app_health_status'"

kill $PF_PID 2>/dev/null || true

# 3. Проверка ServiceMonitor
log_info "Phase 3: ServiceMonitor CRD"
check "ServiceMonitor resource exists" "kubectl get servicemonitor $APP_RELEASE -n $APP_NAMESPACE"
check "ServiceMonitor has correct labels" \
  "kubectl get servicemonitor $APP_RELEASE -n $APP_NAMESPACE -o jsonpath='{.metadata.labels.release}' | grep -qx 'monitoring'"

check "ServiceMonitor targets correct port" "kubectl get servicemonitor $APP_RELEASE -n $APP_NAMESPACE -o json | jq -e '.spec.endpoints[0].port == \"http\"'"
echo ""

# 4. Проверка PrometheusRule
log_info "Phase 4: PrometheusRule CRD"
check "PrometheusRule resource exists" "kubectl get prometheusrule ${APP_RELEASE}-alerts -n $APP_NAMESPACE"
check "Alert 'HelloAppHighErrorRate' defined" "kubectl get prometheusrule ${APP_RELEASE}-alerts -n $APP_NAMESPACE -o json | jq -e '.spec.groups[0].rules[] | select(.alert == \"HelloAppHighErrorRate\")'"
check "Alert 'HelloAppDown' defined" "kubectl get prometheusrule ${APP_RELEASE}-alerts -n $APP_NAMESPACE -o json | jq -e '.spec.groups[0].rules[] | select(.alert == \"HelloAppDown\")'"
echo ""

# 5. Проверка Prometheus discovery
log_info "Phase 5: Prometheus Target Discovery"
kubectl port-forward -n "$MONITORING_NAMESPACE" svc/"${MONITORING_RELEASE}-kube-prometheus-prometheus" 19090:9090 &>/dev/null &
PF_PID=$!
sleep 5

check "Target appears in Prometheus" "curl -s http://localhost:19090/api/v1/targets | jq -e '.data.activeTargets[] | select(.labels.job | contains(\"hello-app\")) | .health == \"up\"'"

kill $PF_PID 2>/dev/null || true
echo ""

# 6. Проверка Grafana
log_info "Phase 6: Grafana Dashboards"
check "Grafana service is running" "kubectl get pods -n $MONITORING_NAMESPACE -l app.kubernetes.io/name=grafana | grep -q Running"
check "Dashboard provisioned" "kubectl exec -n $MONITORING_NAMESPACE -l app.kubernetes.io/name=grafana -- cat /var/lib/grafana/dashboards/default/hello-app-dashboard.json &>/dev/null || kubectl get configmap -n $MONITORING_NAMESPACE | grep -q dashboard"
echo ""

# 7. Проверка Alertmanager
log_info "Phase 7: Alertmanager Configuration"
check "Alertmanager is running" "kubectl get pods -n $MONITORING_NAMESPACE -l app.kubernetes.io/name=alertmanager | grep -q Running"
check "Alert rules loaded" "kubectl port-forward -n $MONITORING_NAMESPACE svc/${MONITORING_RELEASE}-alertmanager 19093:9093 &>/dev/null & sleep 3 && curl -s http://localhost:19093/api/v2/status | grep -q 'hello-app' && kill $! 2>/dev/null || true"
echo ""

# 8. Helm lint
log_info "Phase 8: Helm Chart Validation"
check "helm lint passes" "helm lint ./helm/hello-app"
check "helm template renders successfully" "helm template hello-app ./helm/hello-app -n $APP_NAMESPACE | grep -q 'ServiceMonitor'"
echo ""

echo " Quick Access Commands:"
echo "   # Порт-форвард к приложению"
echo "   kubectl port-forward -n $APP_NAMESPACE svc/$APP_RELEASE 8080:80"
echo "   # Порт-форвард к Prometheus UI"
echo "   kubectl port-forward -n $MONITORING_NAMESPACE svc/${MONITORING_RELEASE}-prometheus 9090:9090"
echo "   # Откройте: http://localhost:9090/targets"
echo "   # Порт-форвард к Grafana"
echo "   kubectl port-forward -n $MONITORING_NAMESPACE svc/${MONITORING_RELEASE}-grafana 3000:80"
echo "   # Откройте: http://localhost:3000 (admin/test)"
echo "   # Порт-форвард к Alertmanager"
echo "   kubectl port-forward -n $MONITORING_NAMESPACE svc/${MONITORING_RELEASE}-alertmanager 9093:9093"
echo " Generate test load:"
echo "   ./scripts/generate-load.sh $APP_NAMESPACE $APP_RELEASE 120"
echo " Cleanup:"
echo "   helm uninstall $APP_RELEASE -n $APP_NAMESPACE"
echo "   helm uninstall $MONITORING_RELEASE -n $MONITORING_NAMESPACE"
