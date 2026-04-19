# Ktech SRE Academy — App

A full-stack training platform for SRE classes with real-time dashboards, class recordings, and a complete observability stack.

---

## Architecture

```
Browser
  │
  ▼
┌─────────────────────────────────────────────────────────────┐
│  Ingress / Nginx (port 80/8081)                             │
│   ├── /            → Frontend (Nginx + static HTML/CSS/JS)  │
│   ├── /api         → Backend (Node.js + Express)            │
│   ├── /socket.io   → Backend (Socket.io real-time)          │
│   └── /metrics     → Backend (Prometheus metrics endpoint)  │
└─────────────────────────────────────────────────────────────┘
  │                         │
  ▼                         ▼
Frontend (Nginx)       Backend (Node.js)
                            │
                            ├── PostgreSQL 15 (users, sessions,
                            │   class_progress, recordings,
                            │   announcements)
                            │
                            └── Uploads PVC (/app/uploads)

Observability Stack (monitoring namespace)
  ├── Prometheus  — scrapes backend + postgres-exporter metrics
  ├── Grafana     — dashboards (reads Prometheus + Loki)
  ├── Loki        — log aggregation
  ├── Promtail    — log shipping from all pods → Loki
  └── Jaeger      — distributed tracing (OTLP from backend)
```

### Components

| Component | Image | Namespace | Description |
|-----------|-------|-----------|-------------|
| Frontend | `kotidevops/kt-frontend:v6` | `sre-platform` | Nginx serving static HTML/CSS/JS |
| Backend | `kotidevops/kt-backend:v6` | `sre-platform` | Node.js + Express + Socket.io |
| PostgreSQL | `postgres:15-alpine` | `sre-platform` | Relational DB (StatefulSet) |
| postgres-exporter | `prometheuscommunity/postgres-exporter:v0.15.0` | `sre-platform` | Exports PG metrics to Prometheus |
| Prometheus | upstream | `monitoring` | Metrics scraping + storage |
| Grafana | upstream | `monitoring` | Dashboards |
| Loki | upstream | `monitoring` | Log aggregation |
| Promtail | upstream | `monitoring` | Log collection DaemonSet |
| Jaeger | upstream | `monitoring` | Distributed tracing |
| Locust | upstream | `sre-platform` | Load testing UI |

### Kubernetes Namespaces

- `sre-platform` — application workloads (frontend, backend, postgres, locust)
- `monitoring` — observability stack (prometheus, grafana, loki, promtail, jaeger)
- `ingress-nginx` — NGINX Ingress Controller

### Storage

| PVC | Size | Used by |
|-----|------|---------|
| `postgres-pvc` | 5 Gi | PostgreSQL data |
| `uploads-pvc` | 20 Gi | Backend file uploads |

Minikube uses `storageclass-minikube.yaml` (`provisioner: k8s.io/minikube-hostpath`).
EKS uses `storageclass-eks.yaml` (`provisioner: ebs.csi.aws.com`, gp3).

### Ingress Hostnames

| Host | Target |
|------|--------|
| `app.ktech.io` | Frontend service (port 80) |
| `api.ktech.io` | Backend service (port 3001) |
| `locust.ktech.io` | Locust master (port 8089) |
| `grafana.ktech.io` | Grafana (port 3000) |
| `prometheus.ktech.io` | Prometheus (port 9090) |
| `jaeger.ktech.io` | Jaeger UI (port 16686) |

---

## Deployment — Docker Compose

### Prerequisites

- Docker Desktop (or Docker Engine + Compose plugin)
- Free ports: `8081`, `3000`, `9090`

### Setup

```bash
cd app/
cp .env.example .env        # edit if needed
docker compose up -d --build
```

### Verify

```bash
docker compose ps
docker compose logs -f backend
```

### Access

| Service | URL |
|---------|-----|
| App | http://localhost:8081 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| Backend health | http://localhost:8081/health |
| Backend metrics | http://localhost:8081/metrics |

### Stop

```bash
docker compose down
# add -v to also remove volumes
```

---

## Deployment — Kubernetes (Minikube)

### Prerequisites

- `minikube` (Docker driver recommended)
- `kubectl`
- Docker Desktop or Docker Engine
- 6 GB RAM + 3 CPUs available for minikube

### One-command deploy

```bash
cd app/k8s/
./minikube.sh deploy
```

This script:
1. Starts minikube (6 GB RAM, 3 CPUs) if not already running
2. Enables the `ingress` addon
3. Starts `minikube tunnel` in the background (assigns `127.0.0.1` to LoadBalancer services)
4. Builds Docker images into minikube's daemon (optional — see flags below)
5. Applies all manifests in order: namespace → storageclass → configmap → postgres → backend → frontend → locust → monitoring stack → ingress

### Deploy flags

```bash
./minikube.sh deploy                  # use existing images (fastest)
./minikube.sh deploy --build          # rebuild images for native arch into minikube
./minikube.sh deploy --multi-arch     # build linux/amd64 + linux/arm64 into minikube
./minikube.sh deploy --push           # build multi-arch + push to Docker Hub, then deploy
```

### Configure /etc/hosts (one-time)

```bash
echo "127.0.0.1 app.ktech.io api.ktech.io locust.ktech.io" | sudo tee -a /etc/hosts
echo "127.0.0.1 grafana.ktech.io prometheus.ktech.io jaeger.ktech.io" | sudo tee -a /etc/hosts
```

### Port-forwards (alternative to /etc/hosts)

```bash
kubectl port-forward svc/frontend-service       8080:80    -n sre-platform
kubectl port-forward svc/backend-service        3001:3001  -n sre-platform
kubectl port-forward svc/locust-master-service  8089:8089  -n sre-platform
kubectl port-forward svc/prometheus-service     9090:9090  -n monitoring
kubectl port-forward svc/grafana-service        3000:3000  -n monitoring
kubectl port-forward svc/loki-service           3100:3100  -n monitoring
kubectl port-forward svc/jaeger-service        16686:16686 -n monitoring
```

### Verify

```bash
kubectl get pods -n sre-platform
kubectl get pods -n monitoring
kubectl get ingress -A
```

### Teardown

```bash
./minikube.sh teardown        # prompts before deleting namespaces
./minikube.sh teardown --yes  # skip confirmation
```

---

## Deployment — Kubernetes (AWS EKS)

### Prerequisites

- `kubectl` configured for the EKS cluster (`aws eks update-kubeconfig ...`)
- `aws` CLI with permissions to create addons and tag security groups
- Docker + `docker buildx` (only needed with `--build`)
- EKS cluster with:
  - Worker nodes (≥ 2 nodes, `t3.medium` or larger)
  - IAM role for the EBS CSI driver (required for persistent volumes)

### One-command deploy

```bash
cd app/k8s/
./deploy-eks.sh deploy
```

This script:
1. Verifies kubectl context points at EKS
2. Installs NGINX Ingress Controller (AWS NLB mode) if not present
3. Tags the node security group for NLB auto-discovery
4. Installs the EBS CSI driver addon if not present (waits until ACTIVE)
5. Applies all manifests with `gp3` storage class substituted in for `standard`
6. Injects Grafana dashboard JSON files as a ConfigMap
7. Applies ingress resources for both `sre-platform` and `monitoring` namespaces
8. Waits for all rollouts to complete and prints the NLB hostname

### Deploy flags

```bash
./deploy-eks.sh deploy                # use existing Docker Hub images
./deploy-eks.sh deploy --build        # build multi-arch + push to Docker Hub, then deploy
./deploy-eks.sh deploy --push         # alias for --build
```

### DNS setup (after deploy)

Get the NLB hostname:
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Add CNAME records in Route53 (or `/etc/hosts` for testing):
```
app.ktech.io         CNAME  <nlb-hostname>
api.ktech.io         CNAME  <nlb-hostname>
locust.ktech.io      CNAME  <nlb-hostname>
grafana.ktech.io     CNAME  <nlb-hostname>
prometheus.ktech.io  CNAME  <nlb-hostname>
jaeger.ktech.io      CNAME  <nlb-hostname>
```

### Port-forwards (quick local access without DNS)

```bash
kubectl port-forward svc/frontend-service       8080:80    -n sre-platform
kubectl port-forward svc/backend-service        3001:3001  -n sre-platform
kubectl port-forward svc/locust-master-service  8089:8089  -n sre-platform
kubectl port-forward svc/prometheus-service     9090:9090  -n monitoring
kubectl port-forward svc/grafana-service        3000:3000  -n monitoring
kubectl port-forward svc/loki-service           3100:3100  -n monitoring
kubectl port-forward svc/jaeger-service        16686:16686 -n monitoring
```

### Verify

```bash
kubectl get pods -n sre-platform
kubectl get pods -n monitoring
kubectl get svc  -n ingress-nginx
```

### Teardown

```bash
./deploy-eks.sh teardown        # prompts before deleting
./deploy-eks.sh teardown --yes  # skip confirmation
```

---

## Kubernetes Manifests Reference

```
k8s/
├── namespace.yaml              # sre-platform namespace
├── configmap.yaml              # app config (env vars) + postgres init SQL + secrets
├── storageclass-minikube.yaml  # hostpath storage class for minikube
├── storageclass-eks.yaml       # gp3 EBS storage class for EKS
├── postgres.yaml               # StatefulSet + Service + PVC (with postgres-exporter sidecar)
├── backend.yaml                # Deployment + Service + uploads PVC
├── frontend.yaml               # Deployment + Service
├── ingress-minikube.yaml       # Ingress (LoadBalancer + host rules) for minikube
├── ingress-eks.yaml            # Ingress (NLB host rules) for EKS
├── locust/
│   └── locust.yaml             # Locust master + worker Deployments + Services
├── monitoring/
│   ├── namespace.yaml          # monitoring namespace
│   ├── rbac.yaml               # ClusterRole for Prometheus pod discovery
│   ├── prometheus.yaml         # Deployment + Service + ConfigMap
│   ├── grafana.yaml            # Deployment + Service + provisioning ConfigMap
│   ├── loki.yaml               # StatefulSet + Service
│   ├── promtail.yaml           # DaemonSet + Service
│   ├── jaeger.yaml             # Deployment + Service
│   └── ingress.yaml            # Ingress rules for monitoring services
├── minikube.sh                 # Deploy/teardown script for minikube
└── deploy-eks.sh               # Deploy/teardown script for EKS
```

---

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| App (admin) | `admin@ktech.sre` | `Admin@123` |
| App (student) | `student@ktech.sre` | `Student@123` |
| Grafana | `admin` | `Grafana@123` |

> **Production note:** Change `JWT_SECRET` and `POSTGRES_PASSWORD` in `k8s/configmap.yaml` before deploying to production.

---

## Building Images

Images are hosted on Docker Hub as `kotidevops/kt-backend:v6` and `kotidevops/kt-frontend:v6`.

To build and push manually:

```bash
# Build multi-arch and push
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t kotidevops/kt-backend:v6 ./backend

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t kotidevops/kt-frontend:v6 ./frontend
```

Or use the deploy scripts with the `--push` flag — they handle builder creation automatically.
