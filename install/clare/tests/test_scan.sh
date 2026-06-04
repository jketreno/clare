#!/usr/bin/env bash
set -euo pipefail

# Simple smoke test for the env-scan script
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/clare-env-scan.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "Missing script: $SCRIPT" >&2
  exit 2
fi

# Use a private temp file so concurrent/multi-user runs don't collide.
OUTPUT="$(mktemp)"
trap 'rm -f "$OUTPUT"' EXIT

# Ensure JSON mode runs
bash "$SCRIPT" --json >"$OUTPUT"

# Validate the JSON. Prefer jq when present; otherwise fall back to python3,
# which the scanner already requires for JSON mode. A missing jq must not fail
# the test — only genuinely invalid JSON should.
if command -v jq >/dev/null 2>&1; then
  validator=(jq .)
elif command -v python3 >/dev/null 2>&1; then
  validator=(python3 -m json.tool)
else
  echo "Neither jq nor python3 available to validate JSON; skipping smoke test" >&2
  exit 0
fi

"${validator[@]}" "$OUTPUT" >/dev/null 2>&1 || {
  echo "JSON output invalid; printing raw output:" >&2
  cat "$OUTPUT"
  exit 3
}

echo "env-scan smoke test passed"
