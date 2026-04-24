# Helm + ArgoCD Deployment Guide

## Prerequisites

- `kubectl` configured and pointing at your cluster (minikube or EKS)
- `helm` v3 installed
- `git` push access to `https://github.com/myproject-vs/ktech-sre-academy.git`

---

## Step 1 — Push the helm branch

```bash
git add helm/
git commit -m "add helm charts and argocd manifests"
git push origin helm
```

ArgoCD will pull from this branch. The branch must be pushed before you bootstrap.

---

## Step 2 — Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl rollout status deployment/argocd-server -n argocd
```

Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Access the UI via port-forward (open http://localhost:8080 in your browser, login: admin):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

---

## Step 3 — Bootstrap the App of Apps

Apply the ArgoCD Project and root Application once. After this, ArgoCD manages everything.

```bash
kubectl apply -f helm/argocd/projects/ktech-project.yaml
kubectl apply -f helm/argocd/app-of-apps.yaml
```

ArgoCD will discover and sync `sre-platform` and `monitoring` automatically.

Check sync status:

```bash
kubectl get applications -n argocd
```

---

## What gets deployed

| Application    | Namespace      | Components |
|----------------|----------------|------------|
| `sre-platform` | `sre-platform` | frontend, backend, postgres, ingress, storageclass |
| `monitoring`   | `monitoring`   | Prometheus, Grafana, Loki, Promtail, Jaeger, Alertmanager, Mailhog |

---

## Environment switching

The `sre-platform` app defaults to `values-minikube.yaml`. To switch to EKS, edit `helm/argocd/apps/sre-platform-app.yaml`:

```yaml
helm:
  valueFiles:
    - values-eks.yaml   # change from values-minikube.yaml
```

Commit and push — ArgoCD picks up the change automatically.

---

## Overriding secrets

Secrets default to placeholder values. Override them in the ArgoCD Application or at install time.

**Via ArgoCD UI:** Applications → sre-platform → App Details → Parameters tab → add overrides.

**Via ArgoCD Application manifest** (edit `helm/argocd/apps/sre-platform-app.yaml`):

```yaml
helm:
  parameters:
    - name: secrets.jwtSecret
      value: <your-jwt-secret>
    - name: secrets.postgresPassword
      value: <your-pg-password>
```

**Via Helm directly (no ArgoCD):**

```bash
helm upgrade --install sre-platform helm/sre-platform \
  -n sre-platform --create-namespace \
  -f helm/sre-platform/values-minikube.yaml \
  --set secrets.jwtSecret=<your-secret>
```

---

## Manual Helm deploy (without ArgoCD)

```bash
# App stack (minikube)
helm upgrade --install sre-platform helm/sre-platform \
  -n sre-platform --create-namespace \
  -f helm/sre-platform/values-minikube.yaml

# Monitoring stack
helm upgrade --install monitoring helm/monitoring \
  -n monitoring --create-namespace

# App stack (EKS)
helm upgrade --install sre-platform helm/sre-platform \
  -n sre-platform --create-namespace \
  -f helm/sre-platform/values-eks.yaml \
  --set secrets.jwtSecret=$JWT_SECRET \
  --set secrets.postgresPassword=$PG_PASSWORD
```

---

## Verify the deployment

```bash
# Check pods
kubectl get pods -n sre-platform
kubectl get pods -n monitoring

# Check ingress
kubectl get ingress -n sre-platform

# Port-forward Grafana (if no ingress)
kubectl port-forward svc/grafana-service -n monitoring 3000:3000
# Open http://localhost:3000  (admin / Grafana@123)

# Port-forward Jaeger
kubectl port-forward svc/jaeger-service -n monitoring 16686:16686
```

---

## Tear down

```bash
# Via Helm
helm uninstall sre-platform -n sre-platform
helm uninstall monitoring -n monitoring

# Via ArgoCD (deletes apps and their resources)
kubectl delete application sre-platform monitoring ktech-sre-root -n argocd
```
