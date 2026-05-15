# hello_world_observability_test
Минимальный рабочий пример приложения с Prometheus-метриками для тестирования observability stack на базе kube-prometheus-stack.
## Быстрый старт

### Предварительные требования
- Kubernetes кластер (minikube/k3d/production)
- Helm 3.x
- kubectl настроен на целевой кластер

### 1. Установка monitoring stack

```bash
# Добавить репозиторий
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Создать неймспейс
kubectl create namespace monitoring

# Установить kube-prometheus-stack с кастомными настройками
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f helm/monitoring-values.yaml
