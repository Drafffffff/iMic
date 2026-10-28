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
mkdir -p "$OUT" "$ROOT/build/release-work.noindex"
OUT=$(cd "$OUT" && pwd -P)
WORK=$(mktemp -d "$ROOT/build/release-work.noindex/run.XXXXXX")
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
# 正式签名：IMIC_RELEASE_IDENTITY="Developer ID Application: …"（私钥须已在本机钥匙串）。
# 公证：再设置 IMIC_NOTARY_PROFILE（先用 `xcrun notarytool store-credentials` 保存凭据）。
RELEASE_IDENTITY=${IMIC_RELEASE_IDENTITY:-}
NOTARY_PROFILE=${IMIC_NOTARY_PROFILE:-}
if [ -n "$RELEASE_IDENTITY" ]; then
  security find-identity -v -p codesigning | grep -Fq "\"$RELEASE_IDENTITY\"" || {
    echo "钥匙串中没有可用的签名身份：$RELEASE_IDENTITY（证书需带私钥）。" >&2; exit 1; }
  echo "==> 构建 Mac 通用版（Apple Silicon + Intel，$RELEASE_IDENTITY）"
else
  echo "==> 构建 Mac 通用版（Apple Silicon + Intel，ad-hoc 签名）"
fi
IMIC_ARCH=universal IMIC_BUILD_DIR="$WORK/mac" IMIC_SIGNING_IDENTITY=- \
  "$ROOT/scripts/build-mac.sh"
APP="$WORK/mac/iMic.app"
if [ -n "$RELEASE_IDENTITY" ]; then
  # Hardened runtime and a secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$RELEASE_IDENTITY" \
    --identifier com.drafffffff.imic --entitlements "$ROOT/mac/iMic.entitlements" "$APP"
fi
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
if [ -n "$RELEASE_IDENTITY" ]; then
  codesign --force --timestamp --sign "$RELEASE_IDENTITY" "$WORK/$MAC_NAME"
  if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> 提交 Apple 公证"
    xcrun notarytool submit "$WORK/$MAC_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$WORK/$MAC_NAME"
    spctl --assess --type open --context context:primary-signature -v "$WORK/$MAC_NAME"
  else
    echo "提示：未设置 IMIC_NOTARY_PROFILE，DMG 已签名但未公证。" >&2
  fi
fi
mv -f "$WORK/$MAC_NAME" "$OUT/$MAC_NAME"

"$ROOT/scripts/package-ios.sh" "$OUT"
(
  cd "$OUT"
  shasum -a 256 "$MAC_NAME" "$IOS_NAME" > SHA256SUMS.txt
)
printf '\n发布文件：\n%s\n%s\n%s\n' "$OUT/$MAC_NAME" "$OUT/$IOS_NAME" "$OUT/SHA256SUMS.txt"
if [ -z "$RELEASE_IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; then
  echo "Mac 版未公证，首次打开可能需要在系统设置中手动允许。"
fi
echo "iOS 版未签名，安装前必须使用自己的 Apple ID/团队签名。"
