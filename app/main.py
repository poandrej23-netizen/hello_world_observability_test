#!/usr/bin/env python3

import os
import time
import random
import logging
from flask import Flask, jsonify, request
from prometheus_client import (
    Counter, Histogram, Gauge, Info, 
    generate_latest, CONTENT_TYPE_LATEST, CollectorRegistry
)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)


registry = CollectorRegistry()


INFO = Info('app', 'Application information', registry=registry)
INFO.info({
    'version': os.getenv('APP_VERSION', '1.0.0'),
    'environment': os.getenv('ENVIRONMENT', 'development'),
    'build_date': os.getenv('BUILD_DATE', 'unknown')
})


REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status', 'handler'],
    registry=registry
)

ERROR_COUNT = Counter(
    'app_errors_total',
    'Total application errors',
    ['type', 'endpoint'],
    registry=registry
)


REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency',
    ['endpoint', 'method'],
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
    registry=registry
)


ACTIVE_REQUESTS = Gauge(
    'app_active_requests',
    'Number of currently active requests',
    registry=registry
)


HEALTH_STATUS = Gauge(
    'app_health_status',
    'Application health status (1=healthy, 0=unhealthy)',
    registry=registry
)
HEALTH_STATUS.set(1)


def track_metrics(endpoint_name: str):
    """Декоратор для автоматического трекинга метрик запросов."""
    def decorator(func):
        def wrapper(*args, **kwargs):
            ACTIVE_REQUESTS.inc()
            start_time = time.time()
            status = '200'
            
            try:
                response = func(*args, **kwargs)
                # Извлекаем статус код из ответа Flask
                if isinstance(response, tuple):
                    status = str(response[1]) if len(response) > 1 else '200'
                elif hasattr(response, 'status_code'):
                    status = str(response.status_code)
                return response
            except Exception as e:
                status = '500'
                ERROR_COUNT.labels(type=type(e).__name__, endpoint=endpoint_name).inc()
                logger.error(f"Error in {endpoint_name}: {e}")
                raise
            finally:
                duration = time.time() - start_time
                REQUEST_LATENCY.labels(endpoint=endpoint_name, method=request.method).observe(duration)
                REQUEST_COUNT.labels(
                    method=request.method,
                    endpoint=endpoint_name,
                    status=status,
                    handler='flask'
                ).inc()
                ACTIVE_REQUESTS.dec()
        wrapper.__name__ = func.__name__
        return wrapper
    return decorator

#endpoints

@app.route('/health')
@track_metrics('health')
def health():
    """Health check endpoint для Kubernetes liveness/readiness probes."""
    if random.random() < 0.01:
        HEALTH_STATUS.set(0)
        return jsonify({'status': 'degraded', 'message': 'Temporary issue'}), 503
    
    HEALTH_STATUS.set(1)
    return jsonify({'status': 'healthy', 'version': INFO._value['version']}), 200

@app.route('/ready')
@track_metrics('ready')
def ready():
    """Readiness probe endpoint."""
    return jsonify({'ready': True}), 200

@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint."""
    return generate_latest(registry), 200, {'Content-Type': CONTENT_TYPE_LATEST}

@app.route('/')
@app.route('/api/hello')
@track_metrics('hello')
def hello():
    """Основной эндпоинт приложения."""
    name = request.args.get('name', 'World')
    
    if random.random() < 0.1:
        time.sleep(random.uniform(0.3, 1.5))
    
    if random.random() < 0.02:
        ERROR_COUNT.labels(type='SimulatedError', endpoint='hello').inc()
        return jsonify({'error': 'Simulated failure'}), 500
    
    return jsonify({
        'message': f'Hello, {name}!',
        'timestamp': time.time(),
        'pod': os.getenv('HOSTNAME', 'unknown')
    }), 200

@app.route('/api/slow')
@track_metrics('slow')
def slow():
    """Эндпоинт с искусственной задержкой для тестирования latency-метрик."""
    delay = float(request.args.get('delay', 1.0))
    time.sleep(min(delay, 10.0))  # Максимум 10 секунд
    return jsonify({'message': f'Done after {delay}s', 'pod': os.getenv('HOSTNAME')}), 200

@app.route('/api/error')
@track_metrics('error')
def error():
    """Эндпоинт для генерации ошибок (тестирование алертов)."""
    error_type = request.args.get('type', 'internal')
    ERROR_COUNT.labels(type=error_type, endpoint='error').inc()
    
    if error_type == 'timeout':
        return jsonify({'error': 'Request timeout'}), 504
    elif error_type == 'not_found':
        return jsonify({'error': 'Resource not found'}), 404
    else:
        return jsonify({'error': 'Internal server error'}), 500

if __name__ == '__main__':
    port = int(os.getenv('PORT', 8080))
    logger.info(f"Starting Hello-Observability app on port {port}")
    logger.info(f"Metrics available at: http://localhost:{port}/metrics")
    app.run(host='0.0.0.0', port=port, threaded=True)
