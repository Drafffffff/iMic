#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
exec python3 -m http.server "${PORT:-8787}" -d "$ROOT/site" --bind 127.0.0.1
