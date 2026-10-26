#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
PORT=${IMIC_TEST_PORT:-47844}
CODE=$([[ $(date +%S) -lt 30 ]] && echo 246810 || echo 135790)
WORK=$(mktemp -d /tmp/imic-link-test.XXXXXX)
LOG="$WORK/mac.log"
CLIENT="$ROOT/build/tools/imic-client"
MAC_PID=""

cleanup() {
  if [ -n "$MAC_PID" ] && kill -0 "$MAC_PID" 2>/dev/null; then
    kill "$MAC_PID" 2>/dev/null || true
    wait "$MAC_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> 1/4 生成测试语音"
TEXT=${IMIC_TEST_TEXT:-"把今天讨论的交互细节整理成一页说明，保留按住说话松开即输入的节奏。"}
VOICE=$(say -v '?' 2>/dev/null | awk '/zh_CN/{print; exit}' | sed -E 's/[[:space:]]+zh_CN.*//')
if [ -n "$VOICE" ]; then
  say -v "$VOICE" -o "$WORK/speech.aiff" "$TEXT" 2>/dev/null
else
  say -o "$WORK/speech.aiff" "This is an iMic end to end test."
fi
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/speech.aiff" "$WORK/speech.wav" >/dev/null
python3 - "$WORK/speech.wav" "$WORK/speech.pcm" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'rb') as w:
    data = w.readframes(w.getnframes())
open(sys.argv[2], 'wb').write(data)
PY

echo "==> 2/4 构建联调客户端"
mkdir -p "$ROOT/build/tools"
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework Network -framework CryptoKit \
  "$ROOT/shared/iMicLink.swift" "$ROOT/shared/PolishOptions.swift" "$ROOT/tools/imic-client/main.swift" \
  -o "$CLIENT"

# 避免模拟器里的 iPhone 应用自动重连并抢走测试连接。
if [ "${IMIC_KEEP_SIMULATOR:-0}" != 1 ]; then
  xcrun simctl terminate booted com.drafffffff.imic 2>/dev/null || true
fi

echo "==> 3/4 启动无界面 Mac（端口 ${PORT}，配对码 ${CODE}）"
"${IMIC_BUILD_DIR:-$ROOT/build/mac.noindex}/iMic.app/Contents/MacOS/iMic" \
  --headless --pair-code="$CODE" --no-input --port="$PORT" > "$LOG" 2>&1 &
MAC_PID=$!
for _ in $(seq 1 40); do
  grep -q HEADLESS_READY "$LOG" 2>/dev/null && break
  sleep 0.2
done
grep -q HEADLESS_READY "$LOG" || { echo "Mac 服务未就绪"; cat "$LOG"; exit 1; }

echo "==> 4/4 配对并发送音频"
set +e
"$CLIENT" --pcm="$WORK/speech.pcm" --code="$CODE" \
  --host=127.0.0.1 --port="$PORT" \
  --device-id-file="$WORK/device-id" --token-file="$WORK/token" \
  --timeout=45 ${IMIC_CLIENT_ARGS:-} | tee "$WORK/client.log"
RC=${PIPESTATUS[0]}
set -e

echo
echo "---- Mac 日志 ----"
cat "$LOG"

if [ "$RC" -ne 0 ]; then
  echo "失败：客户端退出码 $RC" >&2
  exit "$RC"
fi
if ! grep -q "RESULT_BEGIN" "$WORK/client.log"; then
  echo "失败：没有收到识别结果" >&2
  exit 1
fi
TEXT=$(awk '/RESULT_BEGIN/{flag=1;next}/RESULT_END/{flag=0}flag' "$WORK/client.log" | tr -d '\n')
if [ -z "$TEXT" ]; then
  echo "失败：识别结果为空" >&2
  exit 1
fi
echo
echo "PASS：$TEXT"
