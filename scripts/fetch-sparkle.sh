#!/bin/bash
set -euo pipefail
# Official release asset: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
VENDOR="$ROOT/build/vendor"
ARCHIVE="$VENDOR/Sparkle-$SPARKLE_VERSION.tar.xz"
mkdir -p "$VENDOR"
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$ARCHIVE.download"
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
echo "$SPARKLE_SHA256  $ARCHIVE" | shasum -a 256 -c -
# Re-extract the verified archive, never trust an old extracted framework/tool.
STAGING=$(mktemp -d "$VENDOR/.sparkle.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
tar -xJf "$ARCHIVE" -C "$STAGING"
rm -rf "$VENDOR/Sparkle"
mv "$STAGING" "$VENDOR/Sparkle"
echo "Sparkle ${SPARKLE_VERSION}：SHA-256 校验通过。"
