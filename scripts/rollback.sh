#!/usr/bin/env bash
# Roll the deployment back to a prior ImageStreamTag.
#
# Usage:
#   scripts/rollback.sh <target-tag>          # e.g. d1b98f3
#   scripts/rollback.sh                       # picks the second-most-recent tag
#
# What it does (mirror of scripts/build.sh):
#   1. Repoints `:latest` at the target tag -> image trigger rolls the deploy
#   2. Reads APP_GIT_SHA / APP_BUILD_TIME from the target image's ENV
#      (baked in by the Dockerfile ARGs at build time) so the rollback uses
#      the *actual* metadata of that image, not a guess.
#   3. Rewrites the app-build-info ConfigMap to match.
#   4. Patches the pod-template build-info-checksum annotation so the
#      rollout fires deterministically even if the image trigger has
#      nothing to change (e.g. already at this digest).
#   5. Waits for rollout.
#
# Requires: oc, jq, shasum/sha256sum, kubeadmin context.

set -euo pipefail

NAMESPACE=${NAMESPACE:-dotnet-demo}
APP=${APP:-dotnet-openshift-demo}

# Pick target tag: argument, or second-most-recent tag in the ImageStream.
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET=$(oc get is "$APP" -n "$NAMESPACE" -o json \
    | jq -r '.status.tags
        | map(select(.tag != "latest"))
        | sort_by(.items[0].created)
        | reverse
        | .[1].tag // empty')
  if [ -z "$TARGET" ]; then
    echo "error: no rollback target found (need at least 2 sha tags besides latest)" >&2
    exit 1
  fi
  echo "==> No tag given, picking second-most-recent: $TARGET"
fi

if ! oc get istag "$APP:$TARGET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "error: ImageStreamTag $APP:$TARGET not found in $NAMESPACE" >&2
  echo "available tags:" >&2
  oc get is "$APP" -n "$NAMESPACE" -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}' >&2
  exit 1
fi

echo "==> Repointing $APP:latest -> $APP:$TARGET"
oc tag -n "$NAMESPACE" "$APP:$TARGET" "$APP:latest"

echo "==> Reading APP_* env from image labels"
ENV_JSON=$(oc get istag "$APP:$TARGET" -n "$NAMESPACE" -o json \
  | jq -r '.image.dockerImageMetadata.Config.Env[]')
APP_GIT_SHA=$(echo "$ENV_JSON" | awk -F= '$1=="APP_GIT_SHA"{print $2}')
APP_IMAGE_TAG=$(echo "$ENV_JSON" | awk -F= '$1=="APP_IMAGE_TAG"{print $2}')
APP_BUILD_TIME=$(echo "$ENV_JSON" | awk -F= '$1=="APP_BUILD_TIME"{print $2}')
APP_VERSION=$(echo "$ENV_JSON" | awk -F= '$1=="APP_VERSION"{print $2}')

# Sensible fallbacks if the image predates the ARGs being set.
[ -z "$APP_GIT_SHA" ]   && APP_GIT_SHA="$TARGET"
[ -z "$APP_IMAGE_TAG" ] && APP_IMAGE_TAG="$TARGET"
[ -z "$APP_BUILD_TIME" ] && APP_BUILD_TIME="unknown"
[ -z "$APP_VERSION" ]   && APP_VERSION="0.0.1"

echo "    APP_GIT_SHA    = $APP_GIT_SHA"
echo "    APP_IMAGE_TAG  = $APP_IMAGE_TAG"
echo "    APP_BUILD_TIME = $APP_BUILD_TIME"

echo "==> Restoring ConfigMap app-build-info"
oc create configmap app-build-info -n "$NAMESPACE" \
  --from-literal=APP_NAME="$APP" \
  --from-literal=APP_VERSION="$APP_VERSION" \
  --from-literal=APP_GIT_SHA="$APP_GIT_SHA" \
  --from-literal=APP_IMAGE_TAG="$APP_IMAGE_TAG" \
  --from-literal=APP_BUILD_TIME="$APP_BUILD_TIME" \
  --dry-run=client -o yaml | oc apply -f -

CHECKSUM=$(oc get configmap app-build-info -n "$NAMESPACE" -o json \
  | jq -S '.data' \
  | (command -v sha256sum >/dev/null && sha256sum || shasum -a 256) \
  | awk '{print $1}')

echo "==> Patching pod-template checksum=${CHECKSUM:0:12}..."
oc patch deployment "$APP" -n "$NAMESPACE" --type=merge -p "$(cat <<EOF
{"spec":{"template":{"metadata":{"annotations":{"app.kubernetes.io/build-info-checksum":"${CHECKSUM}"}}}}}
EOF
)"

echo "==> Waiting for rollout..."
oc rollout status deployment/"$APP" -n "$NAMESPACE" --timeout=180s

echo
HOST=$(oc get route "$APP" -n "$NAMESPACE" -o jsonpath='{.spec.host}')
echo "--- /info ---"
curl -sk "https://$HOST/info" | (command -v jq >/dev/null && jq . || cat)
