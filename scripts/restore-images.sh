#!/usr/bin/env bash
# Restore image(s) from local OCI backups into the cluster ImageStream.
#
# Usage:
#   scripts/restore-images.sh                    # restore every backed-up tag
#   scripts/restore-images.sh d1b98f3            # restore one tag
#   scripts/restore-images.sh d1b98f3 --promote  # also retag :latest -> :d1b98f3
#
# Pairs with backup-images.sh. Useful after `crc delete && crc start`,
# where the internal registry has been wiped but local OCI archives
# survive.
#
# Requires: oc, skopeo, jq.

set -euo pipefail

NAMESPACE=${NAMESPACE:-dotnet-demo}
APP=${APP:-dotnet-openshift-demo}
BACKUP_DIR=${BACKUP_DIR:-"$(cd "$(dirname "$0")/.."; pwd)/backups/images"}

TARGET_TAG=""
PROMOTE=0
for arg in "$@"; do
  case "$arg" in
    --promote) PROMOTE=1 ;;
    *) TARGET_TAG="$arg" ;;
  esac
done

for tool in oc skopeo jq; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found in PATH" >&2; exit 1; }
done

[ -d "$BACKUP_DIR" ] || { echo "error: backup dir $BACKUP_DIR does not exist" >&2; exit 1; }
[ -f "$BACKUP_DIR/index.json" ] || { echo "error: $BACKUP_DIR/index.json missing" >&2; exit 1; }

REGISTRY_HOST=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -z "$REGISTRY_HOST" ]; then
  echo "==> Enabling default registry route"
  oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"defaultRoute":true}}' >/dev/null
  for _ in $(seq 1 12); do
    REGISTRY_HOST=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)
    [ -n "$REGISTRY_HOST" ] && break
    sleep 5
  done
  [ -z "$REGISTRY_HOST" ] && { echo "error: registry route never appeared" >&2; exit 1; }
fi
echo "==> Registry: $REGISTRY_HOST"

# Make sure the ImageStream and namespace exist (in case we're restoring
# after a fresh cluster bootstrap).
oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc create ns "$NAMESPACE"
oc get is "$APP" -n "$NAMESPACE" >/dev/null 2>&1 || \
  oc create -n "$NAMESPACE" -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: $APP
spec:
  lookupPolicy:
    local: true
EOF

TOKEN=$(oc whoami -t)
USER=$(oc whoami)
echo "==> Logging skopeo in as $USER"
echo "$TOKEN" | skopeo login --tls-verify=false -u "$USER" --password-stdin "$REGISTRY_HOST" >/dev/null

TAGS=()
if [ -n "$TARGET_TAG" ]; then
  TAGS+=("$TARGET_TAG")
else
  while IFS= read -r t; do
    [ -n "$t" ] && TAGS+=("$t")
  done < <(jq -r '.[].tag' "$BACKUP_DIR/index.json")
fi

[ ${#TAGS[@]} -eq 0 ] && { echo "==> Nothing to restore"; exit 0; }

for tag in "${TAGS[@]}"; do
  SRC_DIR="$BACKUP_DIR/$tag"
  if [ ! -d "$SRC_DIR" ]; then
    echo "==> Skipping $tag (no backup at $SRC_DIR)"
    continue
  fi
  echo "==> Restoring $tag -> $REGISTRY_HOST/$NAMESPACE/$APP:$tag"
  skopeo copy \
    --src-tls-verify=false --dest-tls-verify=false \
    "oci:$SRC_DIR:$tag" \
    "docker://$REGISTRY_HOST/$NAMESPACE/$APP:$tag"
done

if [ "$PROMOTE" = 1 ] && [ -n "$TARGET_TAG" ]; then
  echo "==> Promoting $APP:$TARGET_TAG -> $APP:latest"
  oc tag -n "$NAMESPACE" "$APP:$TARGET_TAG" "$APP:latest"
fi

echo
oc get is "$APP" -n "$NAMESPACE" -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}'
