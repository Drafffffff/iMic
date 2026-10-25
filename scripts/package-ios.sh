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
OUTPUT_DIR=${1:-$ROOT/build/release}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P)
IPA_NAME="iMic-$VERSION-iOS-unsigned.ipa"

# 工程、图标和 DerivedData 全部隔离，不改动本地开发工程或带签名的设备构建。
WORK=$(mktemp -d "${TMPDIR:-/tmp}/imic-ios-release.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$WORK" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK/source/ios" "$WORK/package/Payload"
/usr/bin/ditto "$ROOT/ios/iMic" "$WORK/source/ios/iMic"
cp "$ROOT/ios/project.yml" "$WORK/source/ios/project.yml"
cp "$ROOT/ios/Info.plist" "$WORK/source/ios/Info.plist"
/usr/bin/ditto "$ROOT/shared" "$WORK/source/shared"

(
  cd "$WORK/source/ios"
  xcodegen generate
)
xcrun swiftc -swift-version 5 -O "$ROOT/tools/icon.swift" \
  -o "$WORK/icon-gen" -framework AppKit
"$WORK/icon-gen" ios "$WORK/source/ios/iMic/Assets.xcassets/AppIcon.appiconset"

echo "==> 构建未签名 iPhone Release（iOS 17+，arm64）"
xcodebuild \
  -project "$WORK/source/ios/iMic.xcodeproj" \
  -scheme iMic \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$WORK/DerivedData" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  TARGETED_DEVICE_FAMILY=1 \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  build

APP="$WORK/DerivedData/Build/Products/Release-iphoneos/iMic.app"
if [ ! -d "$APP" ]; then
  echo "未生成 iPhone 真机构建：$APP" >&2
  exit 1
fi
PLIST="$APP/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
PLATFORM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$PLIST")
MINIMUM_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")
DEVICE_FAMILY=$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:0' "$PLIST")
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "版本不一致：应用为 $APP_VERSION，VERSION 为 $VERSION。" >&2
  exit 1
fi
if [ "$PLATFORM" != iPhoneOS ] || [ "$MINIMUM_OS" != 17.0 ] || [ "$DEVICE_FAMILY" != 1 ]; then
  echo "拒绝打包：产物必须为 iOS 17+ 的 iPhone 真机构建，不能使用模拟器产物。" >&2
  exit 1
fi
ARCHITECTURES=$(xcrun lipo -archs "$APP/iMic")
if [ "$ARCHITECTURES" != arm64 ]; then
  echo "拒绝打包：真机可执行文件架构应为 arm64，实际为 $ARCHITECTURES。" >&2
  exit 1
fi
# arm64 模拟器与真机架构相同，必须另核对 Mach-O 的平台标记。
BUILD_INFO=$(xcrun vtool -show-build "$APP/iMic")
BINARY_PLATFORM=''
while read -r key value remainder; do
  if [ "$key" = platform ]; then
    BINARY_PLATFORM=$value
  fi
done <<< "$BUILD_INFO"
if [ "$BINARY_PLATFORM" != IOS ]; then
  echo "拒绝打包：Mach-O 平台不是 IOS（实际为 ${BINARY_PLATFORM:-未知}）。" >&2
  exit 1
fi

SIGNING_FILES=$(find "$APP" \( -name embedded.mobileprovision -o -name _CodeSignature \) -print)
if [ -n "$SIGNING_FILES" ]; then
  printf '拒绝公开含设备描述文件或签名目录的产物：\n%s\n' "$SIGNING_FILES" >&2
  exit 1
fi
if /usr/bin/codesign -d "$APP" >/dev/null 2>&1; then
  echo "拒绝公开已签名的 iOS 产物；此脚本只生成未签名 IPA。" >&2
  exit 1
fi

/usr/bin/ditto "$APP" "$WORK/package/Payload/iMic.app"
LEGAL="$WORK/package/Payload/iMic.app/Legal"
mkdir -p "$LEGAL"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$LEGAL/"
/usr/bin/ditto "$ROOT/licenses" "$LEGAL/licenses"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent \
  "$WORK/package/Payload" "$WORK/$IPA_NAME"
mv -f "$WORK/$IPA_NAME" "$OUTPUT_DIR/$IPA_NAME"
printf '已生成：%s\n' "$OUTPUT_DIR/$IPA_NAME"
echo "未签名，需使用自己的 Apple ID/团队重新签名；不是免签/TestFlight。"
