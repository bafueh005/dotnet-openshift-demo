#!/usr/bin/env bash
# Trigger an OpenShift BuildConfig run, then refresh the app-build-info
# ConfigMap and force the Deployment to roll by updating its build-info
# checksum annotation.
#
# Usage:
#   scripts/build.sh                # from main, current HEAD
#   GIT_REF=feature-x scripts/build.sh
#
# Requires: oc, jq, shasum (macOS) or sha256sum (Linux), kubeadmin context.

set -euo pipefail

NAMESPACE=${NAMESPACE:-dotnet-demo}
APP=${APP:-dotnet-openshift-demo}
GIT_REF=${GIT_REF:-main}
GIT_SHA=$(git rev-parse --short HEAD)
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CSPROJ=$(ls -1 *.csproj 2>/dev/null | head -1)
APP_VERSION=$(grep -E '<Version>' "$CSPROJ" 2>/dev/null \
              | sed -E 's/.*<Version>(.*)<\/Version>.*/\1/' \
              | head -1)
[ -z "${APP_VERSION:-}" ] && APP_VERSION=0.0.1

echo "==> Starting OpenShift build for ${APP} @ ${GIT_SHA}"
oc start-build "${APP}" \
  -n "${NAMESPACE}" \
  --commit="$(git rev-parse HEAD)" \
  --build-arg="GIT_SHA=${GIT_SHA}" \
  --build-arg="BUILD_TIME=${BUILD_TIME}" \
  --build-arg="IMAGE_TAG=${GIT_SHA}" \
  --follow

echo "==> Tagging ImageStream :latest -> :${GIT_SHA}"
oc tag -n "${NAMESPACE}" "${APP}:latest" "${APP}:${GIT_SHA}" || true

echo "==> Updating ConfigMap ${APP/-/_}-build-info"
oc create configmap app-build-info \
  -n "${NAMESPACE}" \
  --from-literal=APP_NAME="${APP}" \
  --from-literal=APP_VERSION="${APP_VERSION}" \
  --from-literal=APP_GIT_SHA="${GIT_SHA}" \
  --from-literal=APP_IMAGE_TAG="${GIT_SHA}" \
  --from-literal=APP_BUILD_TIME="${BUILD_TIME}" \
  --dry-run=client -o yaml | oc apply -f -

CHECKSUM=$(oc get configmap app-build-info -n "${NAMESPACE}" -o json \
  | jq -S '.data' \
  | (command -v sha256sum >/dev/null && sha256sum || shasum -a 256) \
  | awk '{print $1}')

echo "==> Patching Deployment with checksum=${CHECKSUM:0:12}..."
oc patch deployment "${APP}" -n "${NAMESPACE}" --type=merge -p "$(cat <<EOF
{"spec":{"template":{"metadata":{"annotations":{"app.kubernetes.io/build-info-checksum":"${CHECKSUM}"}}}}}
EOF
)"

echo "==> Waiting for rollout..."
oc rollout status deployment/"${APP}" -n "${NAMESPACE}" --timeout=180s

# Mirror the just-built image to the local backup store. Best-effort:
# a backup failure should not fail the build itself.
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
if [ -x "$SCRIPT_DIR/backup-images.sh" ] && [ "${SKIP_BACKUP:-0}" != 1 ]; then
  echo "==> Mirroring image ${GIT_SHA} to local backup store"
  "$SCRIPT_DIR/backup-images.sh" "${GIT_SHA}" || \
    echo "warn: backup-images.sh failed -- image is live but not backed up"
fi

echo
echo "Done. Build info:"
oc get configmap app-build-info -n "${NAMESPACE}" -o jsonpath='{.data}' | jq .
echo
HOST=$(oc get route "${APP}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}')
echo "Try:  curl -sk https://${HOST}/info | jq ."
