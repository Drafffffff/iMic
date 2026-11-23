#!/bin/bash
# 手动复现 test-link.sh，但用 open 启动 Mac，让 TCC 以应用自身为责任进程
# （在 Claude Code 等宿主里直接运行 test-link.sh 会因蓝牙隐私检查归到宿主进程而崩溃）。
# 用法：EXTRA="-deepseekEnabled <false/>" run-link-headless.sh <句子> <词库文件绝对路径或空> <标签>
# 需要先 ./scripts/build-mac.sh，并运行一次 test-link.sh 生成 build/tools/imic-client。
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
TEXT="$1"; VOCAB="${2:-}"; TAG="$3"
W=${TMPDIR:-/tmp}/voxchord-vocab-run/$TAG; rm -rf "$W"; mkdir -p "$W"
VOICE=$(say -v '?' | awk '/zh_CN/{print; exit}' | sed -E 's/[[:space:]]+zh_CN.*//')
say -v "$VOICE" -o "$W/s.aiff" "$TEXT"
afconvert -f WAVE -d LEI16@16000 -c 1 "$W/s.aiff" "$W/s.wav" >/dev/null
python3 -I -c "import sys,wave;w=wave.open(sys.argv[1],'rb');open(sys.argv[2],'wb').write(w.readframes(w.getnframes()))" "$W/s.wav" "$W/s.pcm"
PORT=47851; CODE=246810
ARGS=(--headless --pair-code=$CODE --no-input --port=$PORT ${EXTRA:-})
[ -n "$VOCAB" ] && ARGS+=(--vocabulary-file="$VOCAB")
open -n --stdout "$W/mac.log" --stderr "$W/mac.log" "$ROOT/build/mac.noindex/VoxChord.app" --args "${ARGS[@]}"
for _ in $(seq 1 50); do grep -q HEADLESS_READY "$W/mac.log" 2>/dev/null && break; sleep 0.2; done
"$ROOT/build/tools/imic-client" --pcm="$W/s.pcm" --code=$CODE --host=127.0.0.1 --port=$PORT \
  --device-id-file="$W/id" --token-file="$W/token" --timeout=45 > "$W/client.log" 2>&1
echo "client rc=$?"
pkill -f -- "--port=$PORT" || true
sleep 0.5
echo "--- mac"; cat "$W/mac.log"
echo "--- result"; awk '/RESULT_BEGIN/{f=1;next}/RESULT_END/{f=0}f' "$W/client.log"
grep -E "FAILURE|latency|LATENCY" "$W/client.log" | head -3
