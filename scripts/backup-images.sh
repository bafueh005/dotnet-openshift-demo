#!/usr/bin/env bash
# Mirror ImageStream tags to a local OCI archive on this Mac.
#
# Usage:
#   scripts/backup-images.sh                     # back up every sha tag
#   scripts/backup-images.sh d1b98f3             # back up one tag
#
# Layout produced:
#   backups/images/<tag>/                        OCI layout (skopeo copy ... oci:dir)
#   backups/images/index.json                    {tag, digest, source, backedUpAt}
#
# Requires: oc, skopeo, jq.
#
# Notes
# - We back up sha-shaped tags only (skip `latest`, since it just points at
#   one of them and is rebuilt on restore).
# - The local registry route is created on demand the first time the script
#   runs against a fresh cluster.

set -euo pipefail

NAMESPACE=${NAMESPACE:-dotnet-demo}
APP=${APP:-dotnet-openshift-demo}
BACKUP_DIR=${BACKUP_DIR:-"$(cd "$(dirname "$0")/.."; pwd)/backups/images"}
TARGET_TAG="${1:-}"

for tool in oc skopeo jq; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found in PATH" >&2; exit 1; }
done

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

TOKEN=$(oc whoami -t)
USER=$(oc whoami)
echo "==> Logging skopeo in as $USER"
echo "$TOKEN" | skopeo login --tls-verify=false -u "$USER" --password-stdin "$REGISTRY_HOST" >/dev/null

mkdir -p "$BACKUP_DIR"

# Build list of tags to back up.
TAGS=()
if [ -n "$TARGET_TAG" ]; then
  TAGS+=("$TARGET_TAG")
else
  while IFS= read -r t; do
    [ -n "$t" ] && TAGS+=("$t")
  done < <(oc get is "$APP" -n "$NAMESPACE" \
            -o jsonpath='{range .status.tags[*]}{.tag}{"\n"}{end}' \
          | grep -v '^latest$' || true)
fi

if [ ${#TAGS[@]} -eq 0 ]; then
  echo "==> Nothing to back up (no sha tags found)"
  exit 0
fi

INDEX="$BACKUP_DIR/index.json"
[ -f "$INDEX" ] || echo '[]' > "$INDEX"

for tag in "${TAGS[@]}"; do
  DIGEST=$(oc get istag "$APP:$tag" -n "$NAMESPACE" -o jsonpath='{.image.metadata.name}' 2>/dev/null || true)
  if [ -z "$DIGEST" ]; then
    echo "==> Skipping $tag (no such istag)"
    continue
  fi

  TARGET="$BACKUP_DIR/$tag"
  if [ -f "$TARGET/index.json" ] && jq -e --arg t "$tag" --arg d "$DIGEST" \
       '.[] | select(.tag==$t and .digest==$d)' "$INDEX" >/dev/null 2>&1; then
    echo "==> $tag already backed up ($DIGEST), skipping"
    continue
  fi

  echo "==> Backing up $tag ($DIGEST) -> $TARGET"
  rm -rf "$TARGET"
  mkdir -p "$TARGET"
  skopeo copy --tls-verify=false \
    "docker://$REGISTRY_HOST/$NAMESPACE/$APP:$tag" \
    "oci:$TARGET:$tag"

  # Update index (drop any prior entry for this tag first).
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  TMP=$(mktemp)
  jq --arg t "$tag" --arg d "$DIGEST" --arg s "$REGISTRY_HOST/$NAMESPACE/$APP:$tag" --arg ts "$TS" \
    '[.[] | select(.tag != $t)] + [{tag:$t, digest:$d, source:$s, backedUpAt:$ts}]' \
    "$INDEX" > "$TMP" && mv "$TMP" "$INDEX"
done

echo
echo "==> Backups in $BACKUP_DIR:"
jq -r '.[] | "  \(.tag)\t\(.digest[0:19])...\t\(.backedUpAt)"' "$INDEX"
