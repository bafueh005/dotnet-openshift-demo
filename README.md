# dotnet-openshift-demo

ASP.NET Core 10 Web API on OpenShift. The build pipeline runs entirely
inside the cluster — `BuildConfig` → `ImageStream` → image-triggered
`Deployment` — and ArgoCD reconciles everything else from Git.

## Flow

```
git push main
   │
   ▼
ArgoCD (OpenShift GitOps)
   reconciles k8s/  →  ImageStream, BuildConfig, ConfigMap,
                       Deployment, Service, Route
   │
   ▼  (manual trigger: `./scripts/build.sh`)
OpenShift BuildConfig
   clones repo @ HEAD  →  Docker build with GIT_SHA / BUILD_TIME args
                       →  push to ImageStream `dotnet-openshift-demo:latest`
                       →  also tag `:${git_sha}`
   │
   ▼
scripts/build.sh  (post-build)
   refreshes ConfigMap `app-build-info` with new gitSha/imageTag/buildTime
   patches Deployment pod-template annotation
     `app.kubernetes.io/build-info-checksum`  →  rolling restart
   │
   ▼
image.openshift.io/triggers  on the Deployment
   resolves `:latest` to the new digest  →  pulls the new image
   │
   ▼
Pods restart, envFrom picks up new ConfigMap values
GET /info returns the live gitSha + imageTag + buildTime
```

## Layout

| Path                          | What                                                          |
| ----------------------------- | ------------------------------------------------------------- |
| `Program.cs`                  | Web API; `/`, `/info`, `/health/live`, `/health/ready`        |
| `Dockerfile`                  | Multi-stage, non-root, accepts `GIT_SHA` / `BUILD_TIME` ARGs  |
| `k8s/imagestream.yaml`        | ImageStream `dotnet-openshift-demo` (lookupPolicy.local)      |
| `k8s/buildconfig.yaml`        | Docker-strategy BuildConfig, source = this repo, output = IS  |
| `k8s/configmap.yaml`          | `app-build-info` ConfigMap (data is runtime-managed)          |
| `k8s/deployment.yaml`         | Image trigger + envFrom CM + build-info checksum annotation   |
| `k8s/service.yaml`            | ClusterIP Service on port 80 → container 8080                 |
| `k8s/route.yaml`              | Edge-TLS Route                                                |
| `k8s/namespace.yaml`          | `dotnet-demo`, labelled `argocd.argoproj.io/managed-by`       |
| `argocd/application.yaml`     | ArgoCD `Application` (auto-sync, selfHeal, ignoreDifferences) |
| `scripts/build.sh`            | One-command pipeline: build → tag → CM → checksum → rollout   |

## What ArgoCD owns vs what the pipeline owns

ArgoCD is the source of truth for the **shape** of everything: which
resources exist, their labels, probes, security context, the BuildConfig
spec, the initial ConfigMap. Anything ArgoCD writes can be edited only
via Git.

The pipeline owns three **runtime** fields that ArgoCD explicitly
ignores (`argocd/application.yaml` → `ignoreDifferences`):

| Field                                                                       | Written by                                  |
| --------------------------------------------------------------------------- | ------------------------------------------- |
| `Deployment.spec.template.spec.containers[0].image`                         | OpenShift image-trigger controller          |
| `Deployment.metadata.annotations["image.openshift.io/triggers"]`            | OpenShift image-trigger controller          |
| `Deployment.spec.template.metadata.annotations["…/build-info-checksum"]`    | `scripts/build.sh` after each build         |
| `ConfigMap/app-build-info.data`                                             | `scripts/build.sh` after each build         |

That split is what makes the loop reconcile cleanly: ArgoCD doesn't try
to undo runtime state.

## Local run

```bash
dotnet run
curl http://localhost:8080/info
```

## Cluster bootstrap

```bash
# CRC users: `crc start && eval "$(crc oc-env)"`
oc login --token=... --server=...
oc apply -f argocd/application.yaml
```

When ArgoCD applies the `BuildConfig`, the `ConfigChange` trigger fires
an initial build automatically. That first build uses default ARGs, so
the `/info` endpoint will show `gitSha=unknown` until you run the
pipeline script.

## Trigger a new build

```bash
./scripts/build.sh
```

Single command, in order:

1. `oc start-build` with `--build-arg GIT_SHA=$(git rev-parse --short HEAD)` and `--build-arg BUILD_TIME=$(date -u +…)` — follows the log.
2. `oc tag dotnet-openshift-demo:latest dotnet-openshift-demo:<sha>` so the digest is reachable under both tags.
3. `oc apply` the refreshed `app-build-info` ConfigMap.
4. Compute `sha256(.data)`, `oc patch` it onto the pod template annotation.
5. `oc rollout status` blocks until the new pods are ready.

Verify:

```bash
curl -sk "https://$(oc get route dotnet-openshift-demo -n dotnet-demo -o jsonpath='{.spec.host}')/info"
```

You should see the matching `gitSha`, `imageTag`, and `buildTime`.

## Useful one-liners

```bash
# Pipeline state
oc get builds,is,istag,cm/app-build-info,deploy,route -n dotnet-demo

# ArgoCD app status
oc get application -n openshift-gitops dotnet-openshift-demo

# ArgoCD UI (admin / `oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' | base64 -d`)
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'

# Tail the most recent build
oc logs -f build/$(oc get builds -n dotnet-demo --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}') -n dotnet-demo
```
