#!/usr/bin/env bash
# One-page snapshot of the dotnet-openshift-demo pipeline.
#
# Sections (best-effort; each one degrades independently):
#   CRC, Cluster, ArgoCD, ImageStream, Builds (last 5),
#   ConfigMap, Deployment, Pods, Route + live /info, Local backups.
#
# Usage:  scripts/status.sh
# Requires: oc; optional: crc, jq, python3, curl.

set -uo pipefail

NAMESPACE=${NAMESPACE:-dotnet-demo}
APP=${APP:-dotnet-openshift-demo}
BACKUP_DIR=${BACKUP_DIR:-"$(cd "$(dirname "$0")/.."; pwd)/backups/images"}

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
indent()  { sed 's/^/  /'; }

section "CRC"
if command -v crc >/dev/null 2>&1; then
  crc status 2>/dev/null | head -3 | indent
else
  echo "  (crc CLI not in PATH)"
fi

section "Cluster"
if oc whoami >/dev/null 2>&1; then
  echo "  user:   $(oc whoami)"
  echo "  server: $(oc whoami --show-server)"
else
  echo "  not logged in — `oc login` first"
  exit 0
fi

section "ArgoCD Application"
if oc get application -n openshift-gitops "$APP" >/dev/null 2>&1; then
  oc get application -n openshift-gitops "$APP" -o jsonpath='  sync:     {.status.sync.status}
  health:   {.status.health.status}
  revision: {.status.sync.revision}
'
else
  echo "  (Application $APP not found in openshift-gitops)"
fi

section "ImageStream"
if oc get is "$APP" -n "$NAMESPACE" >/dev/null 2>&1; then
  LATEST=$(oc get istag "$APP:latest" -n "$NAMESPACE" -o jsonpath='{.image.metadata.name}' 2>/dev/null)
  echo "  :latest -> ${LATEST:-(unset)}"
  echo "  tags:"
  oc get is "$APP" -n "$NAMESPACE" -o jsonpath='{range .status.tags[*]}    {.tag}{"\t"}{.items[0].image}{"\n"}{end}' 2>/dev/null
else
  echo "  ImageStream not found in $NAMESPACE"
fi

section "Builds (last 5)"
out=$(oc get builds -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp 2>/dev/null)
if [ -n "$out" ]; then
  echo "$out" | tail -6 | indent
else
  echo "  (no builds)"
fi

section "ConfigMap app-build-info"
cm=$(oc get configmap app-build-info -n "$NAMESPACE" -o jsonpath='{.data}' 2>/dev/null)
if [ -n "$cm" ] && command -v python3 >/dev/null 2>&1; then
  echo "$cm" | python3 -m json.tool 2>/dev/null | indent
elif [ -n "$cm" ]; then
  echo "  $cm"
else
  echo "  not found"
fi

section "Deployment"
if oc get deploy "$APP" -n "$NAMESPACE" >/dev/null 2>&1; then
  oc get deploy "$APP" -n "$NAMESPACE" -o jsonpath='  replicas:            {.status.readyReplicas}/{.spec.replicas}
  image:               {.spec.template.spec.containers[0].image}
  build-info-checksum: {.spec.template.metadata.annotations.app\.kubernetes\.io/build-info-checksum}
'
else
  echo "  not found"
fi

section "Pods"
pods=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v -- '-build$' || true)
if [ -n "$pods" ]; then
  echo "$pods" | indent
else
  echo "  (none)"
fi

section "Route + /info"
HOST=$(oc get route "$APP" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -n "$HOST" ]; then
  echo "  https://$HOST"
  if command -v curl >/dev/null 2>&1; then
    body=$(curl -sk --max-time 5 "https://$HOST/info" 2>/dev/null)
    if [ -n "$body" ]; then
      if command -v python3 >/dev/null 2>&1; then
        echo "$body" | python3 -m json.tool 2>/dev/null | indent
      else
        echo "  $body"
      fi
    else
      echo "  /info: no response (timeout or app down)"
    fi
  fi
else
  echo "  not found"
fi

section "Local image backups"
if [ -f "$BACKUP_DIR/index.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "  \(.tag)\t\(.digest[0:19])...\t\(.backedUpAt)"' "$BACKUP_DIR/index.json"
  else
    cat "$BACKUP_DIR/index.json" | indent
  fi
  echo "  dir: $BACKUP_DIR"
else
  echo "  no backups yet ($BACKUP_DIR/index.json missing)"
fi

echo
