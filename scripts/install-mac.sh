#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SOURCE="${IMIC_BUILD_DIR:-$ROOT/build/mac.noindex}/iMic.app"
TARGET="/Applications/iMic.app"
SUPPORT="$HOME/Library/Application Support/iMic"
DRY_RUN=false
BUILD=false
NO_OPEN=false

usage() {
  echo "用法：./scripts/install-mac.sh [--build] [--no-open] [--dry-run] [-h|--help]"
  echo "  --build    安装前先构建"
  echo "  --no-open  安装后不打开"
  echo "  --dry-run  仅检查，不安装"
  echo "  -h, --help 显示帮助"
}

for ARG in "$@"; do
  case "$ARG" in
    --build) BUILD=true ;;
    --no-open) NO_OPEN=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [ "$BUILD" = true ]; then "$ROOT/scripts/build-mac.sh"; fi

if [ ! -d "$SOURCE" ]; then
  echo "$SOURCE 不存在，请运行 ./scripts/install-mac.sh --build" >&2
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

if { [ -e "$TARGET" ] && [ ! -w "$TARGET" ]; } || [ ! -w /Applications ]; then
  echo "没有写入 /Applications 的权限。请使用管理员账户运行，或在 Finder 中把 $SOURCE 拖入「应用程序」。" >&2
  exit 1
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
if [ "$NO_OPEN" = false ]; then
  open "$TARGET"
  echo "已安装并已打开：$TARGET"
else
  echo "已安装：$TARGET"
fi
echo "首次打开会显示设置向导：百炼 API Key → 辅助功能 → 配对 iPhone。之后可从菜单栏 iMic 图标 → 设置向导… 再次打开。"
if codesign -dv "$TARGET" 2>&1 | grep -q "Signature=adhoc"; then
  echo "这是 ad-hoc 签名版本：若辅助功能列表里已有旧的 iMic，请先删除再重新添加。"
fi
