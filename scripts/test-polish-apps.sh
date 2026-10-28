#!/bin/bash
# 真实应用中的润色扫光自测：在 Chrome、Safari、TextEdit、Zed、Cursor 等应用里
# 打开临时测试文档或测试页，按不同光标位置输入草稿、播放扫光并替换为润色结果，
# 保存各阶段截图和效果日志。会接管前台约 10 分钟，运行期间请不要操作电脑。
#
#   ./scripts/test-polish-apps.sh                       # 全部目标
#   ./scripts/test-polish-apps.sh chrome-input,textedit  # 指定目标
#
# 自测程序与 iMic 使用相同的 Bundle ID 和签名，复用已授予的辅助功能和屏幕录制权限；
# 只在脚本打开的测试文档中输入，从不按回车。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT_ROOT=${IMIC_POLISH_APPS_OUT:-"$ROOT/build/polish-apps"}
RUN="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
APP="$ROOT/build/polish-apps.noindex/iMic.app"
mkdir -p "$APP/Contents/MacOS" "$RUN"

xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework ApplicationServices -framework Vision -framework ScreenCaptureKit -framework CoreImage \
  "$ROOT/shared/IMicLog.swift" "$ROOT/shared/TextRevision.swift" \
  "$ROOT/mac/InputTarget.swift" "$ROOT/mac/PolishPresentation.swift" "$ROOT/mac/TextMarkerGeometry.swift" "$ROOT/mac/TextPolishEffect.swift" \
  "$ROOT/tests/PolishApps/main.swift" -o "$APP/Contents/MacOS/iMic"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.drafffffff.imic</string>
<key>CFBundleName</key><string>iMic</string>
<key>CFBundleExecutable</key><string>iMic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$(cat "$ROOT/VERSION")</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>iMic 润色扫光自测：截取测试输入框以核对动画位置。</string>
</dict></plist>
PLIST
IDENTITY=${IMIC_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" --identifier com.drafffffff.imic --entitlements "$ROOT/mac/iMic.entitlements" "$APP"

echo "结果目录: $RUN"
python3 "$ROOT/tests/PolishApps/run.py" "$RUN" "${1:-}"
