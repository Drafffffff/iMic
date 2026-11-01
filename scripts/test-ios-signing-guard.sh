#!/bin/bash
# Prove refusal happens before any build/device call. All external mutators are stubs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d /tmp/imic-signing-guard.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
for command in xcrun xcodebuild xcodegen swiftc defaults; do
  cat > "$WORK/bin/$command" <<'STUB'
#!/bin/bash
printf 'Unexpected external operation: %s\n' "$0" >> "$IMIC_GUARD_CALLS"
exit 99
STUB
  chmod +x "$WORK/bin/$command"
done
export PATH="$WORK/bin:$PATH" IMIC_GUARD_CALLS="$WORK/calls"
unset IMIC_DEMO_DEVICE IMIC_BUNDLE_ID IMIC_DEV_TEAM || true
for script in install-ios-device.sh site-demo.sh; do
  for team in S889TFV5A4 ABCDE12345; do
    for bundle in art.malette.imic.app art.malette.imic.app.uitests; do
      for mode in dry actual; do
        args=()
        if [ "$mode" = dry ]; then args=(--dry-run); fi
        if IMIC_DEV_TEAM="$team" IMIC_BUNDLE_ID="$bundle" "$ROOT/scripts/$script" ${args[@]+"${args[@]}"} > "$WORK/output" 2>&1; then
          echo "FAIL: $script allowed $team / $bundle / $mode" >&2; exit 1
        fi
        grep -q "拒绝签名" "$WORK/output"
        cat "$WORK/output"
      done
    done
  done
  for team in S889TFV5A4 5H39F98ND4; do
    IMIC_DEV_TEAM="$team" "$ROOT/scripts/$script" --dry-run > "$WORK/output"
    grep -Fxq 'IMIC_BUNDLE_ID: art.malette.imic.dev' "$WORK/output"
    grep -Fxq 'UI tests: art.malette.imic.dev.uitests' "$WORK/output"
    cat "$WORK/output"
  done
  IMIC_DEV_TEAM=5H39F98ND4 IMIC_BUNDLE_ID=art.malette.imic.app "$ROOT/scripts/$script" --dry-run > "$WORK/output"
  grep -Fxq 'IMIC_BUNDLE_ID: art.malette.imic.app' "$WORK/output"
  cat "$WORK/output"
done
for action in archive archive-unsigned export upload handoff; do
  if IMIC_TEAM_ID=S889TFV5A4 "$ROOT/scripts/testflight.sh" "$action" > "$WORK/output" 2>&1; then
    echo "FAIL: TestFlight allowed the wrong team" >&2; exit 1
  fi
  grep -q '5H39F98ND4' "$WORK/output"
done
[ ! -e "$IMIC_GUARD_CALLS" ] || { cat "$IMIC_GUARD_CALLS"; exit 1; }
echo 'PASS: both device entry points refuse release IDs for non-release teams before external operations; dry runs resolve dev/test IDs; TestFlight rejects other teams.'
