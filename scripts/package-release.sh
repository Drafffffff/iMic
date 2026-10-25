#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
VERSION=$(<"$ROOT/VERSION")
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION 必须为三段数字版本号，例如 1.0.0。" >&2
  exit 1
fi
if [ "$#" -gt 1 ]; then
  echo "用法：$0 [输出目录]" >&2
  exit 2
fi
OUT=${1:-$ROOT/build/release}
mkdir -p "$OUT" "$ROOT/build"
OUT=$(cd "$OUT" && pwd -P)
WORK=$(mktemp -d "$ROOT/build/release-work.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$WORK" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MAC_NAME="iMic-$VERSION-macOS-universal.dmg"
IOS_NAME="iMic-$VERSION-iOS-unsigned.ipa"
echo "==> 构建 Mac 通用版（Apple Silicon + Intel，ad-hoc 签名）"
IMIC_ARCH=universal IMIC_BUILD_DIR="$WORK/mac" IMIC_SIGNING_IDENTITY=- \
  "$ROOT/scripts/build-mac.sh"
APP="$WORK/mac/iMic.app"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "Mac 应用版本与 VERSION 不一致。" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
xcrun lipo "$APP/Contents/MacOS/iMic" -verify_arch arm64
xcrun lipo "$APP/Contents/MacOS/iMic" -verify_arch x86_64
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/iMic.app"
ln -s /Applications "$WORK/dmg/Applications"
cp "$ROOT/README.md" "$WORK/dmg/README.md"
hdiutil create -volname "iMic $VERSION" -srcfolder "$WORK/dmg" \
  -format UDZO -fs HFS+ "$WORK/$MAC_NAME"
mv -f "$WORK/$MAC_NAME" "$OUT/$MAC_NAME"

"$ROOT/scripts/package-ios.sh" "$OUT"
(
  cd "$OUT"
  shasum -a 256 "$MAC_NAME" "$IOS_NAME" > SHA256SUMS.txt
)
printf '\n发布文件：\n%s\n%s\n%s\n' "$OUT/$MAC_NAME" "$OUT/$IOS_NAME" "$OUT/SHA256SUMS.txt"
echo "Mac 版未公证，首次打开可能需要在系统设置中手动允许。"
echo "iOS 版未签名，安装前必须使用自己的 Apple ID/团队签名。"
