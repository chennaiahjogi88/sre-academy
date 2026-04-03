# Ktech SRE Training Platform

A full-stack web application for the SRE Batch Jan 2026.

## Stack
- **Frontend**: Nginx + static HTML/JS
- **Backend**: Node.js + Express + Socket.io
- **Database**: PostgreSQL 15
- **Observability**: Prometheus + Grafana
- **Container**: Docker Compose (K8s manifests in /k8s)

## Quick Start

```bash
# Clone / navigate to app directory
cd app/

# Copy env file
cp .env.example .env

# Start everything
docker compose up -d

# View logs
docker compose logs -f
```

## Access

| Service | URL | Credentials |
|---------|-----|-------------|
| Platform | http://localhost | — |
| Grafana | http://localhost:3000 | admin / Grafana@123 |
| Prometheus | http://localhost:9090 | — |
| Backend metrics | http://localhost/metrics | — |

## Default Users

| Role | Email | Password |
|------|-------|----------|
| Admin | admin@ktech.sre | Admin@123 |
| Student | student@ktech.sre | Student@123 |

## K8s Deployment

```bash
# Apply all manifests
kubectl apply -f k8s/

# Check status
kubectl get all -n sre-platform
```

## Observability

The backend exposes Prometheus metrics at `/metrics`:
- `http_requests_total` — request count by method/route/status
- `http_request_duration_seconds` — latency histogram
- `active_websocket_users` — live connected users
- `login_attempts_total` — login success/failure
- `class_views_total` — which classes are being viewed
- `recording_uploads_total` — file upload count

Grafana dashboard auto-provisions at startup.
# ktech-sre-academy
