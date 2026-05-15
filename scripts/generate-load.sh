#!/bin/bash
# scripts/generate-load.sh
# Генерация тестового трафика для проверки метрик и алертов

set -e

NAMESPACE="${1:-hello_world_app}"
SERVICE="${2:-hello_world_app}"
DURATION="${3:-60}"  # секунд

echo "Generating load for ${SERVICE}.${NAMESPACE} for ${DURATION}s..."

if kubectl get svc -n "$NAMESPACE" "$SERVICE" &>/dev/null; then
    URL="http://${SERVICE}.${NAMESPACE}.svc.cluster.local"
else
    echo "Service not found in cluster, using localhost:8080"
    URL="http://localhost:8080"
fi

ENDPOINTS=("/api/hello?name=Test" "/api/hello?name=User" "/api/slow?delay=0.5" "/")

START_TIME=$(date +%s)
REQUEST_COUNT=0
ERROR_COUNT=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ "$ELAPSED" -ge "$DURATION" ]; then
        break
    fi
    
    ENDPOINT="${ENDPOINTS[$((RANDOM % ${#ENDPOINTS[@]}))]}"
    
    if [ $((RANDOM % 100)) -lt 95 ]; then
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "${URL}${ENDPOINT}")
    else
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "${URL}/api/error?type=internal")
    fi
    
    REQUEST_COUNT=$((REQUEST_COUNT + 1))
    
    if [[ ! "$RESPONSE" =~ ^2[0-9][0-9]$ ]]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    sleep 0.1
done

echo "Test complete:"
echo "   Total requests: $REQUEST_COUNT"
echo "   Errors: $ERROR_COUNT ($(( ERROR_COUNT * 100 / REQUEST_COUNT ))%)"
echo "   Duration: ${DURATION}s"
