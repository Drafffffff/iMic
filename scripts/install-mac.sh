#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SOURCE="${IMIC_BUILD_DIR:-$ROOT/build/mac.noindex}/iMic.app"
TARGET="/Applications/iMic.app"
SUPPORT="$HOME/Library/Application Support/iMic"
DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=true; fi

if [ ! -d "$SOURCE" ]; then
  echo "$SOURCE 不存在，请先运行 ./scripts/build-mac.sh" >&2
  exit 1
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")
if [ "$BUNDLE_ID" != "com.drafffffff.imic" ]; then
  echo "拒绝安装：Bundle ID 为 $BUNDLE_ID" >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE"

echo "源: $SOURCE"
echo "目标: $TARGET"
if [ "$DRY_RUN" = true ]; then
  echo "dry-run：未修改任何文件"
  exit 0
fi

mkdir -p "$SUPPORT"
if [ -d "$TARGET" ]; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  BACKUP="$SUPPORT/backups/$STAMP/iMic.app.zip"
  mkdir -p "$(dirname "$BACKUP")"
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$BACKUP"
  unzip -t -q "$BACKUP"
  echo "已备份旧版本: $BACKUP"
fi

# 只停止 iMic 自己的可执行文件，避免误伤同名进程。
pkill -f "$TARGET/Contents/MacOS/iMic" 2>/dev/null || true
sleep 0.4
rm -rf "$TARGET"
ditto "$SOURCE" "$TARGET"
codesign --verify --deep --strict "$TARGET"
open "$TARGET"
echo "已安装并打开: $TARGET"
