# ArgoCD bootstrap

The `application.yaml` here is the single bootstrap manifest. Apply it once
against the cluster where OpenShift GitOps (ArgoCD) is installed:

```bash
oc apply -f argocd/application.yaml
```

From that point ArgoCD watches `k8s/` on the `main` branch and reconciles
changes automatically (`syncPolicy.automated` with prune + selfHeal).

If `openshift-gitops` is not the namespace where your ArgoCD instance lives,
edit `metadata.namespace` to match. Confirm with:

```bash
oc get argocd -A
```
