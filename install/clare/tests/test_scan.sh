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
jq . "$OUTPUT" >/dev/null 2>&1 || {
  echo "JSON output invalid or jq not installed; printing raw output:" >&2
  cat "$OUTPUT"
  exit 3
}

echo "env-scan smoke test passed"
