# dotnet-openshift-demo

ASP.NET Core 10 Web API deployed to OpenShift via ArgoCD (GitOps).

## Flow

```
git push main
   │
   ▼
GitHub Actions  ──► builds image, pushes to ghcr.io,
                    commits new image tag into k8s/deployment.yaml
   │
   ▼
ArgoCD (OpenShift GitOps)  ──► detects k8s/ change, syncs to cluster
   │
   ▼
OpenShift namespace `dotnet-demo`
   Deployment + Service + Route
```

## Layout

| Path                       | What                                              |
| -------------------------- | ------------------------------------------------- |
| `Program.cs`               | Web API with `/`, `/health/live`, `/health/ready` |
| `Dockerfile`               | Multi-stage, non-root, listens on 8080            |
| `k8s/`                     | Deployment, Service, Route, Namespace             |
| `argocd/application.yaml`  | ArgoCD `Application` CR (auto-sync + selfHeal)    |
| `.github/workflows/`       | Build → push → bump tag in `k8s/deployment.yaml`  |

## Local run

```bash
dotnet run
curl http://localhost:8080/health/ready
```

## Container build

```bash
docker build -t dotnet-openshift-demo .
docker run --rm -p 8080:8080 dotnet-openshift-demo
```

## Cluster bootstrap

```bash
oc login --token=... --server=...
oc apply -f argocd/application.yaml
```

ArgoCD takes over from there.
