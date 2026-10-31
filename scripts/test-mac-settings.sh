#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
"$ROOT/scripts/fetch-sparkle.sh"
WORK=$(mktemp -d /tmp/imic-settings-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1]);work=pathlib.Path(sys.argv[2])
source=(root/'mac/main.swift').read_text().split('// MARK: - Entry point')[0]
(work/'AppDelegate.swift').write_text(source)
# Use the production build's source list, rather than maintaining a second UI list.
paths=re.findall(r'"\$ROOT/([^"\n]+\.swift)"', (root/'scripts/build-mac.sh').read_text())
paths=[str(root/p) if p!='mac/main.swift' else str(work/'AppDelegate.swift') for p in paths if p!='tools/icon.swift']
(work/'sources.txt').write_text('\n'.join(paths)+'\n')
PY
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < "$WORK/sources.txt"
xcrun swiftc -D DEBUG -swift-version 5 -framework AppKit -framework Network -framework CryptoKit \
  -F "$ROOT/build/vendor/Sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$ROOT/build/vendor/Sparkle" \
  -framework ApplicationServices -framework Vision -framework ScreenCaptureKit -framework ServiceManagement \
  "${SOURCES[@]}" "$ROOT/tests/MacSettings/main.swift" -o "$WORK/settings-tests"
# Package the harness so Bundle.main resolves both languages just like the real app.
APP="$WORK/SettingsTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/settings-tests" "$APP/Contents/MacOS/settings-tests"
cp -R "$ROOT/mac/Resources/"*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>imic.settings.tests</string><key>CFBundleExecutable</key><string>settings-tests</string><key>CFBundleDevelopmentRegion</key><string>en</string><key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array></dict></plist>
PLIST
"$APP/Contents/MacOS/settings-tests" --ui-preview=settings-external-key "$@"
