#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
VERSION=$(<"$ROOT/VERSION")
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION 必须为三段数字版本号，例如 1.0.0。" >&2
  exit 1
fi
# This preflight also runs for ad-hoc packages: never ship the placeholder key.
python3 "$ROOT/tools/appcast.py" key "$ROOT/mac/sparkle-public-key.txt"
BUILD=$(<"$ROOT/MAC_BUILD")
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "MAC_BUILD 必须为正整数。" >&2; exit 1; }
python3 "$ROOT/tools/appcast.py" check-build "$ROOT/site/appcast.xml" "$BUILD"
if [ "${1:-}" = --check-only ]; then
  echo "PASS：发布公钥与 MAC_BUILD 预检通过；未构建、签名或发布。"
  exit 0
fi
MODE=build
RESUME_ID=""
DMG=""
if [ "${1:-}" = --resume-notarization ]; then
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "用法：$0 --resume-notarization <submission-id> <dmg> [输出目录]" >&2
    exit 2
  fi
  MODE=resume
  RESUME_ID=$2
  DMG=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$3")
  OUT=${4:-$ROOT/build/release}
else
  if [ "$#" -gt 1 ] || [[ "${1:-}" = --* ]]; then
    echo "用法：$0 [输出目录 | --check-only]；或 --resume-notarization <id> <dmg> [输出目录]" >&2
    exit 2
  fi
  OUT=${1:-$ROOT/build/release}
fi
mkdir -p "$OUT" "$ROOT/build/release-work.noindex"
OUT=$(cd "$OUT" && pwd -P)
WORK=$(mktemp -d "$ROOT/build/release-work.noindex/run.XXXXXX")
MOUNT=""
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
  # Keep partially/fully signed code on release failure, including timestamp errors.
  # The submitted DMG lives outside WORK and is never removed by this trap.
  if [ "$status" -ne 0 ] && [ -n "${RELEASE_IDENTITY:-}" ]; then
    echo "保留发布工作目录：$WORK" >&2
    if [ -n "$DMG" ] && [ -f "$DMG" ]; then echo "保留已签名 DMG：$DMG" >&2; fi
  else
    rm -rf "$WORK" || true
  fi
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
if [ "$MODE" = resume ]; then
  # No Developer ID signing on resume, but keep all release identity checks.
  RELEASE_IDENTITY=${RELEASE_IDENTITY:-Developer ID Application: KE CHENG (5H39F98ND4)}
fi
if [ -n "$RELEASE_IDENTITY" ]; then
  case "$RELEASE_IDENTITY" in
    "Developer ID Application: "*"(5H39F98ND4)") ;;
    *) echo "发布版必须使用团队 5H39F98ND4 的 Developer ID Application 身份。" >&2; exit 1 ;;
  esac
  [ -n "$NOTARY_PROFILE" ] || { echo "自动更新发布必须设置 IMIC_NOTARY_PROFILE，确保最终 DMG 已公证。" >&2; exit 1; }
  # Read the full output before matching: grep -q exits early and, under pipefail, the
  # writer's SIGPIPE turns a match into a failure (intermittently).
  if [ "$MODE" != resume ]; then
    IDENTITIES=$(security find-identity -v -p codesigning)
    grep -Fq "\"$RELEASE_IDENTITY\"" <<<"$IDENTITIES" || {
      echo "钥匙串中没有可用的签名身份：${RELEASE_IDENTITY}（证书需带私钥）。" >&2; exit 1; }
  fi
  echo "==> 构建/恢复 Mac 通用版（Apple Silicon + Intel，${RELEASE_IDENTITY}）"
else
  echo "==> 构建/恢复 Mac 通用版（Apple Silicon + Intel，ad-hoc 签名）"
fi
if [ "$MODE" = resume ]; then
  [ "$(basename "$DMG")" = "$MAC_NAME" ] || { echo "DMG 文件名与 VERSION 不一致。" >&2; exit 1; }
  codesign --verify --strict "$DMG"
  TEAM=$(codesign -dv "$DMG" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ "$TEAM" = 5H39F98ND4 ] || { echo "DMG 签名团队不匹配。" >&2; exit 1; }
  # Inspect the retained, signed app without modifying or re-signing the image.
  MOUNT="$WORK/mounted"
  mkdir -p "$MOUNT"
  hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
  ditto "$MOUNT/iMic.app" "$WORK/iMic.app"
  hdiutil detach "$MOUNT"
  MOUNT=""
  APP="$WORK/iMic.app"
  "$ROOT/scripts/fetch-sparkle.sh"
else
  IMIC_CONFIGURATION=release IMIC_ARCH=universal IMIC_BUILD_DIR="$WORK/mac" IMIC_SIGNING_IDENTITY=- \
    "$ROOT/scripts/build-mac.sh"
  APP="$WORK/mac/iMic.app"
  if [ -n "$RELEASE_IDENTITY" ]; then
    "$ROOT/scripts/sign-mac.sh" "$APP" "$RELEASE_IDENTITY" release
    TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [ "$TEAM" = 5H39F98ND4 ] || {
      echo "Developer ID 团队不匹配。" >&2; exit 1; }
  fi
fi
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
if [ "$APP_VERSION" != "$VERSION" ] || [ "$APP_BUILD" != "$BUILD" ]; then
  echo "Mac 应用版本/构建号与 VERSION / MAC_BUILD 不一致。" >&2
  exit 1
fi
if [ -n "$RELEASE_IDENTITY" ]; then
  TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ "$TEAM" = 5H39F98ND4 ] || { echo "App 签名团队不匹配。" >&2; exit 1; }
  APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
  [ "$APP_KEY" = "$(cat "$ROOT/mac/sparkle-public-key.txt")" ] || { echo "App 更新公钥不匹配。" >&2; exit 1; }
fi
codesign --verify --deep --strict "$APP"
xcrun lipo "$APP/Contents/MacOS/iMic" -verify_arch arm64
xcrun lipo "$APP/Contents/MacOS/iMic" -verify_arch x86_64
if [ "$MODE" != resume ]; then
  mkdir -p "$WORK/dmg"
  ditto "$APP" "$WORK/dmg/iMic.app"
  ln -s /Applications "$WORK/dmg/Applications"
  cp "$ROOT/README.md" "$WORK/dmg/README.md"
  hdiutil create -volname "iMic $VERSION" -srcfolder "$WORK/dmg" \
    -format UDZO -fs HFS+ "$WORK/$MAC_NAME"
  DMG="$WORK/$MAC_NAME"
  if [ -n "$RELEASE_IDENTITY" ]; then
    python3 "$ROOT/tools/release-network.py" retry -- \
      codesign --force --timestamp --sign "$RELEASE_IDENTITY" "$DMG"
    # Move the exact signed bytes OUTSIDE the disposable work directory BEFORE
    # submitting. A lost connection must not destroy the only resumable artifact.
    mkdir -p "$ROOT/build/notarization-pending"
    PENDING=$(mktemp -d "$ROOT/build/notarization-pending/$VERSION-$BUILD.XXXXXX")
    mv "$DMG" "$PENDING/$MAC_NAME"
    DMG="$PENDING/$MAC_NAME"
  fi
fi
if [ -n "$RELEASE_IDENTITY" ]; then
  # Single submit, then <=8 status polls and <=8 staple attempts, with a shared
  # 30-minute deadline. Only Accepted can reach stapling and Sparkle signing.
  if [ "$MODE" = resume ]; then
    python3 "$ROOT/tools/release-network.py" notarize --dmg "$DMG" \
      --profile "$NOTARY_PROFILE" --output-directory "$OUT" --resume "$RESUME_ID"
  else
    python3 "$ROOT/tools/release-network.py" notarize --dmg "$DMG" \
      --profile "$NOTARY_PROFILE" --output-directory "$OUT"
  fi
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
# Sign exactly the final notarized, stapled bytes that will be uploaded.
if [ -n "$RELEASE_IDENTITY" ]; then
  spctl -a -vv "$APP"
  SIGNATURE=$("$ROOT/build/vendor/Sparkle/bin/sign_update" -p "$DMG")
  swift "$ROOT/tools/verify-update.swift" "$ROOT/mac/sparkle-public-key.txt" "$SIGNATURE" "$DMG"
fi
PENDING_DMG=""
if [ "$DMG" != "$OUT/$MAC_NAME" ]; then
  PENDING_DMG="$DMG"
  cp -f "$PENDING_DMG" "$OUT/$MAC_NAME"
fi

"$ROOT/scripts/package-ios.sh" "$OUT"
(
  cd "$OUT"
  shasum -a 256 "$MAC_NAME" "$IOS_NAME" > SHA256SUMS.txt
)
if [ -n "$RELEASE_IDENTITY" ]; then
  NOTES="$ROOT/docs/releases/v$VERSION.md"
  [ -f "$NOTES" ] || { echo "缺少发布说明：$NOTES" >&2; exit 1; }
  python3 "$ROOT/tools/appcast.py" update "$ROOT/site/appcast.xml" "$BUILD" "$VERSION" "$OUT/$MAC_NAME" "$SIGNATURE" "$NOTES"
  echo "appcast 已在本地更新。先上传 DMG 到 Release，再提交并推送 site/appcast.xml；本脚本不会发布。"
fi
if [ -n "$PENDING_DMG" ]; then
  rm -f "$PENDING_DMG" "${PENDING_DMG%.dmg}.notarization.json"
  case "$(dirname "$PENDING_DMG")" in
    "$ROOT/build/notarization-pending/"*) rm -rf "$(dirname "$PENDING_DMG")" ;;
  esac
fi
DMG="$OUT/$MAC_NAME"
printf '\n发布文件：\n%s\n%s\n%s\n' "$OUT/$MAC_NAME" "$OUT/$IOS_NAME" "$OUT/SHA256SUMS.txt"
if [ -z "$RELEASE_IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; then
  echo "Mac 版未公证，首次打开可能需要在系统设置中手动允许。"
fi
echo "iOS 版未签名，安装前必须使用自己的 Apple ID/团队签名。"
