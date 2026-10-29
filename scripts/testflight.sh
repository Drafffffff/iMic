#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ACTION=${1:-help}
if [ "$#" -gt 1 ]; then echo "用法：$0 archive|archive-unsigned|check|export|upload" >&2; exit 2; fi
case "$ACTION" in
  archive|archive-unsigned|check|export|upload) ;;
  help|--help|-h)
    cat <<'HELP'
用法：./scripts/testflight.sh archive|archive-unsigned|check|export|upload
  archive           使用 Xcode 已登录账号自动签名归档（可能创建/更新描述文件）
  archive-unsigned  无账号时生成未签名归档，供之后签名导出；不能直接分发
  check             检查归档的版本、隐私清单、平台和调试入口
  export            将已有归档签名导出为 App Store Connect IPA（不上传）
  upload            将已有归档签名并上传到 App Store Connect
环境变量：IMIC_TEAM_ID、IMIC_BUILD_NUMBER、IMIC_TESTFLIGHT_DIR、IMIC_PROFILE_PATH
默认为 5H39F98ND4 团队；版本与构建号读取 VERSION 和 ios/project.yml。
自动签名需要团队资源权限；也可用 IMIC_PROFILE_PATH 指定持有人提供的 App Store 描述文件。
上传还需要该团队的有效 App Store Connect 登录及应用记录。
HELP
    exit 0 ;;
  *) echo "未知操作：$ACTION；运行 $0 --help 查看用法。" >&2; exit 2 ;;
esac

VERSION=$(<"$ROOT/VERSION")
PROJECT_VERSION=$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$ROOT/ios/project.yml")
BUILD_NUMBER=${IMIC_BUILD_NUMBER:-$(awk '/CURRENT_PROJECT_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$ROOT/ios/project.yml")}
TEAM=${IMIC_TEAM_ID:-5H39F98ND4}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION 格式无效" >&2; exit 1; }
[ "$PROJECT_VERSION" = "$VERSION" ] || { echo "ios/project.yml 与 VERSION 不一致" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]] || { echo "Build 应为最多 4.2.2 位的正数字版本，例如 2 或 2.1" >&2; exit 1; }
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "Team ID 格式无效" >&2; exit 1; }
OUTPUT=${IMIC_TESTFLIGHT_DIR:-$ROOT/build/testflight.noindex/$VERSION-$BUILD_NUMBER}
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd -P)
ARCHIVE="$OUTPUT/iMic.xcarchive"
WORK=""
cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_archive() {
  python3 "$ROOT/tools/validate-testflight.py" "$ARCHIVE/Products/Applications/iMic.app" \
    --version "$VERSION" --build "$BUILD_NUMBER" --team "$TEAM"
}

if [ "$ACTION" = archive ] || [ "$ACTION" = archive-unsigned ]; then
  [ ! -e "$ARCHIVE" ] || { echo "归档已存在：$ARCHIVE。请使用 check/export/upload，或递增构建号。" >&2; exit 1; }
  WORK=$(mktemp -d "$OUTPUT/.source.XXXXXX")
  mkdir -p "$WORK/ios"
  ditto "$ROOT/ios/iMic" "$WORK/ios/iMic"
  cp "$ROOT/ios/project.yml" "$ROOT/ios/Info.plist" "$WORK/ios/"
  ditto "$ROOT/shared" "$WORK/shared"
  ditto "$ROOT/tests/iOSUI" "$WORK/tests/iOSUI"
  mkdir -p "$WORK/tools"
  cp "$ROOT/tools/icon.swift" "$WORK/tools/icon.swift"
  cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$WORK/"
  ditto "$ROOT/licenses" "$WORK/licenses"
  (cd "$WORK/ios" && xcodegen generate)
  xcrun swiftc -swift-version 5 -O "$WORK/tools/icon.swift" -o "$WORK/icon-gen" -framework AppKit
  "$WORK/icon-gen" ios "$WORK/ios/iMic/Assets.xcassets/AppIcon.appiconset"
  python3 - "$WORK/ios/iMic/Assets.xcassets/AppIcon.appiconset" <<'PY'
import pathlib,struct,sys
directory=pathlib.Path(sys.argv[1])
for icon in directory.glob('*.png'):
    data=icon.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[25] != 2:
        raise SystemExit(f'图标必须为无 alpha 的 RGB PNG：{icon.name}')
data=(directory/'Icon-1024.png').read_bytes()
if struct.unpack('>II',data[16:24]) != (1024,1024):
    raise SystemExit('App Store 图标必须为 1024×1024')
print('图标校验通过：RGB、无 alpha、1024×1024 marketing icon')
PY
  SIGNING=(CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
  if [ "$ACTION" = archive-unsigned ]; then
    SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
  fi
  xcodebuild -project "$WORK/ios/iMic.xcodeproj" -scheme iMic -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$OUTPUT/DerivedData" \
    -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM" MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" TARGETED_DEVICE_FAMILY=1 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    "${SIGNING[@]}" archive 2>&1 | tee "$OUTPUT/archive-$ACTION.log"
  check_archive | tee "$OUTPUT/validation.txt"
  ditto -c -k --keepParent "$WORK" "$OUTPUT/source.zip"
  git -C "$ROOT" rev-parse HEAD > "$OUTPUT/source-revision.txt"
  git -C "$ROOT" diff --binary HEAD > "$OUTPUT/source-changes.patch"
  echo "归档：$ARCHIVE"
  if [ "$ACTION" = archive-unsigned ]; then echo "此归档未签名；签名导出成功后才能上传/安装。"; fi
  exit 0
fi

[ -d "$ARCHIVE" ] || { echo "请先运行 archive 或 archive-unsigned：$ARCHIVE 不存在" >&2; exit 1; }
check_archive | tee "$OUTPUT/validation.txt"
[ "$ACTION" != check ] || exit 0

# Always produce and validate a local distribution IPA before any upload attempt.
if [ "$ACTION" = upload ]; then "$ROOT/scripts/testflight.sh" export; fi
DESTINATION=export
if [ "$ACTION" = upload ]; then DESTINATION=upload; fi
OPTIONS="$OUTPUT/ExportOptions-$DESTINATION.plist"
CONFIG_COMMAND=(python3 "$ROOT/tools/testflight-export-options.py" --template "$ROOT/ios/TestFlightExportOptions.plist"
  --output "$OPTIONS" --team "$TEAM" --destination "$DESTINATION")
if [ -n "${IMIC_PROFILE_PATH:-}" ]; then CONFIG_COMMAND+=(--profile "$IMIC_PROFILE_PATH"); fi
"${CONFIG_COMMAND[@]}"
EXPORT_COMMAND=(xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUTPUT/$DESTINATION"
  -exportOptionsPlist "$OPTIONS")
if [ -z "${IMIC_PROFILE_PATH:-}" ]; then EXPORT_COMMAND+=(-allowProvisioningUpdates); fi
"${EXPORT_COMMAND[@]}" 2>&1 | tee "$OUTPUT/$DESTINATION.log"
if [ "$ACTION" = export ]; then
  WORK=$(mktemp -d "$OUTPUT/.verify.XXXXXX")
  ditto -x -k "$OUTPUT/export/iMic.ipa" "$WORK"
  python3 "$ROOT/tools/validate-testflight.py" "$WORK/Payload/iMic.app" \
    --version "$VERSION" --build "$BUILD_NUMBER" --team "$TEAM" --require-distribution \
    | tee "$OUTPUT/distribution-validation.txt"
  (cd "$OUTPUT/export" && shasum -a 256 iMic.ipa > SHA256SUMS.txt)
  echo "已导出并校验：$OUTPUT/export/iMic.ipa（尚未上传）"
else
  echo "Xcode 上传完成；请在 App Store Connect 确认 Apple 处理状态后再分配测试组。"
fi
