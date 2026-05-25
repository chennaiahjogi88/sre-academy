# Ktech SRE Academy

A full-stack training platform for SRE classes with real-time dashboards, class recordings, and a complete observability stack.

See **[app/README.md](app/README.md)** for full design and deployment instructions.

---

## Quick Start

### Docker Compose

```bash
cd app/
cp .env.example .env
docker compose up -d --build
```

| Service | URL |
|---------|-----|
| App | http://localhost:8081 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |

### Minikube

```bash
cd app/k8s/
./minikube.sh deploy
```

### EKS

```bash
cd app/k8s/
./deploy-eks.sh deploy
```

---

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| App (admin) | `admin@ktech.sre` | `Admin@123` |
| App (student) | `student@ktech.sre` | `Student@123` |
| Grafana | `admin` | `Grafana@123` |

---
DEMO @ 9th May