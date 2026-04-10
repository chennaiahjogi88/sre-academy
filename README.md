# Ktech SRE Academy — Platform Reference

A production-style SRE training platform deployed on AWS EKS. Students interact with a real web application backed by PostgreSQL, while a full observability stack (metrics, logs, traces) runs alongside it — giving hands-on exposure to every tool in the SRE toolchain.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Layout](#repository-layout)
3. [Application Stack](#application-stack)
   - [Backend](#backend)
   - [Frontend](#frontend)
   - [PostgreSQL](#postgresql)
4. [Infrastructure — EKS](#infrastructure--eks)
   - [Cluster](#cluster)
   - [Storage — EBS gp3](#storage--ebs-gp3)
   - [Namespaces](#namespaces)
5. [Kubernetes Manifests](#kubernetes-manifests)
6. [Monitoring Stack](#monitoring-stack)
   - [Prometheus](#prometheus)
   - [Grafana](#grafana)
   - [Loki](#loki)
   - [Promtail](#promtail)
   - [Jaeger](#jaeger)
7. [Load Testing — Locust](#load-testing--locust)
8. [Docker Images — Multi-Arch Build](#docker-images--multi-arch-build)
9. [Deploy / Teardown](#deploy--teardown)
10. [Accessing Services](#accessing-services)
11. [Querying Logs in Loki](#querying-logs-in-loki)
12. [Alert Rules](#alert-rules)
13. [Default Credentials](#default-credentials)
14. [Production Hardening Checklist](#production-hardening-checklist)

---

## Architecture Overview

```
                        ┌─────────────────────────────────────────────┐
                        │              AWS EKS Cluster                │
                        │  Region: ap-south-2  Cluster: koti-dev-eks  │
                        │                                             │
                        │  ┌─────────────── sre-platform ──────────┐ │
                        │  │  sre-frontend (nginx, x2)             │ │
                        │  │  sre-backend  (Node.js, x2)  ←──────┐ │ │
                        │  │  postgres     (StatefulSet, x1)      │ │ │
                        │  │  locust-master + 2 workers            │ │ │
                        │  └───────────────────────────────────────┘ │
                        │                                             │
                        │  ┌─────────────── monitoring ────────────┐ │
                        │  │  prometheus  (scrapes backend pods)   │ │
                        │  │  grafana     (dashboards + explore)   │ │
                        │  │  loki        (log storage)            │ │
                        │  │  promtail    (DaemonSet log shipper)  │ │
                        │  │  jaeger      (distributed tracing) ───┘ │ │
                        │  └───────────────────────────────────────┘ │
                        └─────────────────────────────────────────────┘

  Trace flow:  backend → OTLP HTTP → jaeger-service:4318
  Metric flow: prometheus → pod annotation scrape → backend:3001/metrics
  Log flow:    promtail (hostPath /var/log/pods) → loki-service:3100
  Grafana:     datasources: Prometheus + Loki + Jaeger (all auto-provisioned)
```

---

## Repository Layout

```
ktech-sre-academy/
├── app/
│   ├── backend/
│   │   ├── Dockerfile              # Multi-arch Node.js image
│   │   ├── package.json
│   │   ├── package-lock.json       # Lock file — keep in sync
│   │   └── src/
│   │       ├── index.js            # Express app entry point
│   │       ├── tracing.js          # OpenTelemetry SDK init
│   │       ├── metrics.js          # prom-client metric definitions
│   │       ├── db.js               # PostgreSQL pool
│   │       └── routes/
│   │           ├── auth.js
│   │           ├── classes.js
│   │           ├── recordings.js
│   │           ├── announcements.js
│   │           └── admin.js
│   ├── frontend/
│   │   ├── Dockerfile              # Multi-stage: node builder → nginx
│   │   ├── nginx/nginx.conf
│   │   └── public/                 # Static HTML/CSS/JS
│   └── k8s/
│       ├── deploy-eks.sh           # One-shot deploy/teardown script
│       ├── namespace.yaml
│       ├── storageclass.yaml       # EBS gp3 StorageClass
│       ├── configmap.yaml          # App config + DB schema + Secrets
│       ├── postgres.yaml           # StatefulSet + PVC (5Gi gp3)
│       ├── backend.yaml            # Deployment + Service + PVC (20Gi)
│       ├── frontend.yaml           # Deployment + Service + Ingress
│       ├── locust/
│       │   └── locust.yaml         # Master + 2 workers + locustfile
│       └── monitoring/
│           ├── namespace.yaml
│           ├── rbac.yaml           # ServiceAccounts + ClusterRoles
│           ├── prometheus.yaml     # Deployment + ConfigMap + AlertRules
│           ├── grafana.yaml        # Deployment + datasource provisioning
│           ├── loki.yaml           # StatefulSet + config (7-day retention)
│           ├── promtail.yaml       # DaemonSet + relabel config
│           └── jaeger.yaml         # all-in-one Deployment (OTLP enabled)
```

---

## Application Stack

### Backend

| Item | Detail |
|------|--------|
| Runtime | Node.js 20 (Alpine) |
| Framework | Express 4 |
| Image | `kotidevops/kt-backend:v2` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Replicas | 2 |
| Port | 3001 |
| Health endpoint | `GET /health` |
| Metrics endpoint | `GET /metrics` (Prometheus format) |

**Key dependencies:**

| Package | Purpose |
|---------|---------|
| `express` | HTTP server + routing |
| `socket.io` | WebSocket — real-time active user count, announcements |
| `pg` | PostgreSQL client |
| `jsonwebtoken` | JWT auth |
| `bcryptjs` | Password hashing |
| `prom-client` | Prometheus metrics exposition |
| `helmet` | HTTP security headers |
| `express-rate-limit` | Rate limiting (200 req/15 min global, 20 login/15 min) |
| `multer` | File uploads (recordings) |
| `@opentelemetry/sdk-node` | OpenTelemetry Node.js SDK |
| `@opentelemetry/auto-instrumentations-node` | Auto-instruments express, pg, http, socket.io |
| `@opentelemetry/exporter-trace-otlp-http` | Ships traces to Jaeger via OTLP HTTP |

**API routes:**

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/auth/login` | — | Login, returns JWT |
| GET | `/api/auth/me` | JWT | Current user info |
| GET | `/api/classes` | JWT | List all classes |
| GET | `/api/recordings` | JWT | List recordings |
| GET | `/api/announcements` | JWT | Active announcements |
| GET | `/api/admin/users` | JWT (admin) | User management |
| GET | `/health` | — | Liveness/readiness check |
| GET | `/metrics` | — | Prometheus metrics |

**Environment variables (from ConfigMap + Secret):**

```
NODE_ENV=production
PORT=3001
PGHOST=postgres-service
PGPORT=5432
PGDATABASE=sre_platform
PGUSER=sre_user
PGPASSWORD=<from secret>
JWT_SECRET=<from secret>
UPLOAD_DIR=/app/uploads
MAX_FILE_SIZE_MB=500
OTEL_SERVICE_NAME=sre-platform-backend
OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-service.monitoring.svc.cluster.local:4318
OTEL_RESOURCE_ATTRIBUTES=service.version=2.0.0,deployment.environment=production
```

**OpenTelemetry tracing (`src/tracing.js`):**

- Loaded via `node --require ./src/tracing.js src/index.js` (must be first)
- If `OTEL_EXPORTER_OTLP_ENDPOINT` is not set, tracing is a no-op (safe for local dev)
- Auto-instruments: Express routes, HTTP calls, PostgreSQL queries
- `@opentelemetry/instrumentation-fs` is disabled (too noisy)
- Traces are exported to Jaeger via OTLP HTTP on port `4318`
- Graceful SDK shutdown on `SIGTERM`

**Prometheus metrics (`src/metrics.js`):**

- `http_requests_total` — Counter labelled by method, route, status_code
- `http_request_duration_seconds` — Histogram of response times
- `active_websocket_users` — Gauge tracking live WebSocket connections

Scraped automatically by Prometheus via pod annotations:
```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "3001"
prometheus.io/path: "/metrics"
```

**Resource limits:**

```
requests:  256Mi RAM, 100m CPU
limits:    512Mi RAM, 500m CPU
```

**Persistent storage:** A 20Gi gp3 EBS PVC (`uploads-pvc`) mounted at `/app/uploads` for recording files.

---

### Frontend

| Item | Detail |
|------|--------|
| Build | Two-stage Docker build |
| Stage 1 | `node:20-alpine` — copies static assets from `public/` |
| Stage 2 | `nginx:1.25-alpine` — serves static files |
| Image | `kotidevops/kt-frontend:v1` |
| Replicas | 2 |
| Port | 80 |

The Nginx config (`nginx/nginx.conf`) proxies `/api/*` and `/metrics` requests to `backend-service:3001`, so the frontend and backend share a single hostname via the Ingress.

**Ingress:**

```yaml
ingressClassName: nginx
host: sre.ktech.local        # Update to your real domain or ELB hostname
/   → frontend-service:80
```

**Resource limits:**

```
requests:  64Mi RAM, 50m CPU
limits:    128Mi RAM, 200m CPU
```

---

### PostgreSQL

| Item | Detail |
|------|--------|
| Image | `postgres:15-alpine` |
| Workload | StatefulSet (1 replica) |
| Port | 5432 |
| Database | `sre_platform` |
| User | `sre_user` |
| Storage | 5Gi gp3 EBS PVC (`postgres-pvc`) |
| Init | `init.sql` mounted at `/docker-entrypoint-initdb.d` — runs on first boot |

**Schema (auto-created on first start):**

| Table | Description |
|-------|-------------|
| `users` | Accounts with bcrypt-hashed passwords, roles (admin/student) |
| `sessions` | JWT token registry with JTI tracking and revocation |
| `class_progress` | Per-user slide progress (upserted via WebSocket events) |
| `recordings` | Class recording metadata (file stored on uploads PVC) |
| `announcements` | Platform-wide announcements with expiry support |

Readiness probe: `pg_isready -U sre_user -d sre_platform`

---

## Infrastructure — EKS

### Cluster

| Item | Detail |
|------|--------|
| Provider | AWS EKS |
| Region | `ap-south-2` |
| Cluster name | `koti-dev-eks` |
| Kubernetes | v1.33.8-eks |
| Node | `ip-10-0-2-252.ap-south-2.compute.internal` |

### Storage — EBS gp3

A custom `StorageClass` named `gp3` is applied before any PVC:

```yaml
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # PV created only when pod is scheduled
reclaimPolicy: Retain                     # Data survives PVC deletion
parameters:
  type: gp3
  fsType: ext4
```

Requires the **AWS EBS CSI Driver** addon:
```bash
aws eks create-addon \
  --cluster-name koti-dev-eks \
  --addon-name aws-ebs-csi-driver
```

### Namespaces

| Namespace | Contents |
|-----------|----------|
| `sre-platform` | Frontend, Backend, Postgres, Locust |
| `monitoring` | Prometheus, Grafana, Loki, Promtail, Jaeger |

---

## Kubernetes Manifests

| File | What it creates |
|------|----------------|
| `namespace.yaml` | `sre-platform` namespace |
| `storageclass.yaml` | `gp3` StorageClass backed by EBS CSI |
| `configmap.yaml` | `sre-platform-config` (env vars) + `postgres-init-sql` (schema) + `sre-platform-secrets` (JWT, DB password) |
| `postgres.yaml` | StatefulSet, Service, PVC (5Gi gp3) |
| `backend.yaml` | Deployment (x2), Service, PVC (20Gi gp3 for uploads) |
| `frontend.yaml` | Deployment (x2), Service, Ingress |
| `locust/locust.yaml` | ConfigMap (locustfile.py), Master Deployment, Worker Deployment (x2), Service |
| `monitoring/namespace.yaml` | `monitoring` namespace |
| `monitoring/rbac.yaml` | ServiceAccount + ClusterRole + ClusterRoleBinding for Prometheus and Promtail |
| `monitoring/prometheus.yaml` | ConfigMap (prometheus.yml + alert_rules.yml), Deployment, Service |
| `monitoring/grafana.yaml` | ConfigMap (datasources + dashboard provisioning), Secret, Deployment, Service |
| `monitoring/loki.yaml` | ConfigMap (loki.yaml), StatefulSet, Service |
| `monitoring/promtail.yaml` | ConfigMap (promtail.yaml), DaemonSet |
| `monitoring/jaeger.yaml` | Deployment (all-in-one), Service |

---

## Monitoring Stack

### Prometheus

| Item | Detail |
|------|--------|
| Image | `prom/prometheus:v2.47.0` |
| Port | 9090 |
| Config | `prometheus-config` ConfigMap |
| Retention | 30 days |
| Storage | `emptyDir` (replace with gp3 PVC for production) |
| RBAC | ClusterRole with read access to pods, nodes, services, ingresses |

**Scrape jobs configured:**

1. **`prometheus`** — self-monitoring at `localhost:9090`

2. **`kubernetes-pods`** — auto-discovers pods in `sre-platform` namespace that have:
   ```
   prometheus.io/scrape: "true"
   ```
   Reads port from `prometheus.io/port` and path from `prometheus.io/path`. Carries `namespace`, `pod`, and `app` labels into every metric.

3. **`kubernetes-nodes-cadvisor`** — scrapes cAdvisor on every node via the Kubernetes API server proxy for CPU, memory, and disk metrics per container.

---

### Grafana

| Item | Detail |
|------|--------|
| Image | `grafana/grafana:10.2.0` |
| Port | 3000 |
| Admin password | `Grafana@123` (from `monitoring-secrets`) |
| Datasources | Auto-provisioned via ConfigMap |
| Feature flags | `traceToLogs`, `traceToMetrics` (correlate Jaeger ↔ Loki ↔ Prometheus) |

**Auto-provisioned datasources** (no manual setup required):

| Name | Type | URL |
|------|------|-----|
| Prometheus | prometheus | `http://prometheus-service:9090` |
| Loki | loki | `http://loki-service:3100` |
| Jaeger | jaeger | `http://jaeger-service:16686` |

Prometheus is the default datasource. `traceToLogs` and `traceToMetrics` feature flags enable Grafana to draw links between a Jaeger trace span and the corresponding Loki log lines or Prometheus metrics for the same time window.

Dashboard JSON files placed in `/var/lib/grafana/dashboards/` are auto-loaded every 30 seconds from the `sre-platform` folder.

---

### Loki

| Item | Detail |
|------|--------|
| Image | `grafana/loki:2.9.4` |
| Workload | StatefulSet (1 replica) |
| HTTP port | 3100 |
| gRPC port | 9096 |
| Storage | `emptyDir` (replace with gp3 PVC for production) |
| Retention | 7 days (`168h`) |
| Index | TSDB v13, 24h index period |
| Auth | Disabled (single-tenant) |
| Results cache | Embedded cache, 100 MB |

Loki stores logs as compressed chunks on the local filesystem. Promtail ships logs to `http://loki-service.monitoring.svc.cluster.local:3100/loki/api/v1/push`.

---

### Promtail

| Item | Detail |
|------|--------|
| Image | `grafana/promtail:2.9.4` |
| Workload | DaemonSet (runs on every node) |
| RBAC | ClusterRole: get/list/watch pods, services, nodes |

**How it works:**

1. Mounts the host path `/var/log/pods` (read-only) to access every pod's log files written by the container runtime (CRI format).
2. Also mounts `/var/lib/docker/containers` for older runtimes.
3. Uses `kubernetes_sd_configs` with `role: pod` to discover pods and enrich log streams with Kubernetes metadata.

**Labels attached to every log stream:**

| Label | Source |
|-------|--------|
| `namespace` | `__meta_kubernetes_namespace` |
| `pod` | `__meta_kubernetes_pod_name` |
| `container` | `__meta_kubernetes_pod_container_name` |
| `app` | `__meta_kubernetes_pod_label_app` |
| Any pod label | `labelmap` on `__meta_kubernetes_pod_label_(.+)` |

The `cri: {}` pipeline stage parses the CRI log format (timestamp, stream, flags, message) before shipping to Loki.

---

### Jaeger

| Item | Detail |
|------|--------|
| Image | `jaegertracing/all-in-one:1.54` |
| Storage | In-memory (max 10,000 traces) |
| OTLP gRPC | 4317 |
| OTLP HTTP | 4318 |
| Jaeger UI | 16686 |
| Jaeger thrift | 14268 |

`COLLECTOR_OTLP_ENABLED=true` enables the OTLP receiver so the backend's OpenTelemetry SDK can ship traces directly without a Jaeger agent.

The backend connects via:
```
OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger-service.monitoring.svc.cluster.local:4318
```

For production, replace in-memory storage with Elasticsearch or Cassandra.

---

## Load Testing — Locust

| Item | Detail |
|------|--------|
| Image | `locustio/locust:2.24.0` |
| Master | 1 pod — hosts the web UI on port 8089 |
| Workers | 2 pods — execute the actual HTTP load |
| Target | `http://backend-service:3001` |
| Script | `locustfile.py` embedded in a ConfigMap |

**Simulated user types:**

| Class | Weight | Behaviour |
|-------|--------|-----------|
| `SREPlatformStudent` | 10 | Logs in, browses classes, checks announcements, views recordings |
| `SREPlatformAdmin` | 1 | Logs in as admin, lists users |

**Task weights (student):**

| Task | Weight | Endpoint |
|------|--------|----------|
| Browse classes | 8 | `GET /api/classes` |
| Health check | 6 | `GET /health` |
| View announcements | 5 | `GET /api/announcements` |
| List recordings | 4 | `GET /api/recordings` |
| Auth me | 2 | `GET /api/auth/me` |
| Failed login | 1 | `POST /api/auth/login` (wrong creds) — triggers `HighLoginFailureRate` alert |

Workers connect to the master via ports 5557/5558.

---

## Docker Images — Multi-Arch Build

Both images are built for `linux/amd64` and `linux/arm64` using Docker Buildx.

**Backend Dockerfile:**

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev          # Reproducible install from lock file; dev deps excluded
COPY src/ ./src/
RUN mkdir -p /app/uploads
EXPOSE 3001
CMD ["node", "--require", "./src/tracing.js", "src/index.js"]
```

`--require ./src/tracing.js` ensures OpenTelemetry is initialised before any other module loads.

**Build and push:**

```bash
# Ensure package-lock.json is up to date locally first
npm install --omit=dev

# Build and push multi-arch manifest
docker buildx build \
  --builder multi-builder \
  --platform linux/amd64,linux/arm64 \
  -t kotidevops/kt-backend:v2 \
  --push \
  app/backend/
```

**Frontend Dockerfile (two-stage):**

```dockerfile
# Stage 1 — copy public assets
FROM node:20-alpine AS builder
WORKDIR /app
COPY public/ ./public/

# Stage 2 — serve with nginx
FROM nginx:1.25-alpine
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /app/public/ /usr/share/nginx/html/
RUN chown -R nginx:nginx /usr/share/nginx/html && chmod -R 755 /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Deploy / Teardown

The `deploy-eks.sh` script handles the full lifecycle.

**Prerequisites:**

- `kubectl` configured for the EKS cluster (`aws eks update-kubeconfig ...`)
- AWS EBS CSI Driver addon installed on the cluster
- Docker Hub images pushed (see above)

**Deploy everything:**

```bash
cd app/k8s
bash deploy-eks.sh deploy
```

The script will:
1. Verify kubectl context contains `eks` or `koti-dev`
2. Check for the EBS CSI DaemonSet
3. Apply all app manifests in dependency order (namespace → storage → config → postgres → backend → frontend → locust)
4. Apply all monitoring manifests (namespace → RBAC → loki → promtail → jaeger → prometheus → grafana)
5. Wait for rollout of: Postgres, Backend, Frontend, Loki, Prometheus, Grafana, Jaeger
6. Print the access guide

**Skip confirmation prompts:**

```bash
bash deploy-eks.sh deploy --yes
```

**Tear everything down:**

```bash
bash deploy-eks.sh teardown
# or
bash deploy-eks.sh teardown --yes
```

Teardown deletes resources in reverse order and waits for both namespaces to fully terminate.

---

## Accessing Services

All services are `ClusterIP` — use `kubectl port-forward` for local access.

| Service | Command | URL |
|---------|---------|-----|
| Frontend | `kubectl port-forward svc/frontend-service 8080:80 -n sre-platform` | http://localhost:8080 |
| Backend API | `kubectl port-forward svc/backend-service 3001:3001 -n sre-platform` | http://localhost:3001 |
| Locust UI | `kubectl port-forward svc/locust-master-service 8089:8089 -n sre-platform` | http://localhost:8089 |
| Grafana | `kubectl port-forward svc/grafana-service 3000:3000 -n monitoring` | http://localhost:3000 |
| Prometheus | `kubectl port-forward svc/prometheus-service 9090:9090 -n monitoring` | http://localhost:9090 |
| Loki | `kubectl port-forward svc/loki-service 3100:3100 -n monitoring` | http://localhost:3100 |
| Jaeger UI | `kubectl port-forward svc/jaeger-service 16686:16686 -n monitoring` | http://localhost:16686 |

**Check pod status:**

```bash
kubectl get pods -n sre-platform
kubectl get pods -n monitoring
```

**View logs of any pod:**

```bash
kubectl logs -f deployment/sre-backend -n sre-platform
kubectl logs -f deployment/grafana -n monitoring
```

---

## Querying Logs in Loki

### Via Grafana Explore (recommended)

```bash
kubectl port-forward svc/grafana-service 3000:3000 -n monitoring
```

Open `http://localhost:3000` → **Explore** → select **Loki** datasource.

**LogQL cheat sheet:**

```logql
# All backend logs
{namespace="sre-platform", app="sre-backend"}

# All frontend logs
{namespace="sre-platform", app="sre-frontend"}

# Filter for errors
{namespace="sre-platform"} |= "error"

# Logs from a specific pod
{pod="sre-backend-7d96b76b64-5vzt9"}

# All monitoring stack logs
{namespace="monitoring"}

# Parse JSON and filter by level
{namespace="sre-platform"} | json | level="error"

# Count error lines per minute
count_over_time({namespace="sre-platform"} |= "error" [1m])
```

### Via Loki HTTP API (curl)

```bash
kubectl port-forward svc/loki-service 3100:3100 -n monitoring
```

```bash
# Last 1 hour of backend logs
curl -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="sre-platform",app="sre-backend"}' \
  --data-urlencode "start=$(date -v-1H +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode "limit=100" | jq '.data.result[].values[][1]'

# List all available labels
curl http://localhost:3100/loki/api/v1/labels | jq

# Values for a specific label
curl http://localhost:3100/loki/api/v1/label/app/values | jq
```

### Via LogCLI

```bash
brew install logcli
export LOKI_ADDR=http://localhost:3100

# Tail live logs (like kubectl logs -f)
logcli query '{namespace="sre-platform",app="sre-backend"}' --tail

# Last 50 lines
logcli query '{namespace="sre-platform"}' --limit=50

# Search for a string
logcli query '{namespace="sre-platform"} |= "error"' --limit=100

# Show all label streams
logcli labels
logcli series '{namespace="sre-platform"}'
```

---

## Alert Rules

Defined in the `prometheus-config` ConfigMap (`alert_rules.yml`) and evaluated every 15 seconds.

| Alert | Expression | Threshold | Severity | For |
|-------|-----------|-----------|----------|-----|
| `HighLoginFailureRate` | `rate(login_attempts_total{result="failure"}[5m])` | > 0.5/sec | warning | 2m |
| `BackendDown` | `up{job="kubernetes-pods",app="sre-backend"}` | == 0 | critical | 30s |
| `HighAPILatency` | `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))` | > 1s | warning | 5m |
| `NoActiveUsers` | `active_websocket_users` | == 0 | info | 30m |
| `HighErrorRate` | `rate(http_requests_total{status_code=~"5.."}[5m])` | > 0.1/sec | warning | 2m |

`HighLoginFailureRate` is intentionally triggered by the Locust `failed_login` task — useful for demoing alert firing in class.

---

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| App (admin) | `admin@ktech.sre` | `Admin@123` |
| App (student) | `student@ktech.sre` | `Student@123` |
| Grafana | `admin` | `Grafana@123` |
| PostgreSQL | `sre_user` | `sre_password_2024` |

---

## Production Hardening Checklist

- [ ] Replace `emptyDir` volumes on Loki and Prometheus with gp3 PVCs (20Gi+)
- [ ] Replace Jaeger in-memory storage with Elasticsearch or Cassandra
- [ ] Rotate all secrets (`JWT_SECRET`, `POSTGRES_PASSWORD`, `GRAFANA_PASSWORD`) — use AWS Secrets Manager or Kubernetes External Secrets
- [ ] Set up NGINX Ingress Controller with an AWS NLB and real domain (update `frontend.yaml` host)
- [ ] Enable TLS on the Ingress (cert-manager + ACM or Let's Encrypt)
- [ ] Add HorizontalPodAutoscaler on `sre-backend` and `sre-frontend`
- [ ] Enable Alertmanager and configure notification receivers (Slack, PagerDuty)
- [ ] Restrict Prometheus and Loki to authenticated access
- [ ] Add network policies to isolate `sre-platform` ↔ `monitoring` traffic
- [ ] Add multi-node EKS node group for HA (currently single node)
- [ ] Upgrade `multer` to v2.x (v1.x has known CVEs)
