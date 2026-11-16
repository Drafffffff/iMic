#!/bin/bash
# Only controls the simulator whose UDID this script created and recorded locally.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
exec python3 tools/site-capture.py "$@"
