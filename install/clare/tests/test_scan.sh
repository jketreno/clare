#!/usr/bin/env bash
set -euo pipefail

# Simple smoke test for the env-scan script
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/clare-env-scan.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "Missing script: $SCRIPT" >&2
  exit 2
fi

# Ensure JSON mode runs
bash "$SCRIPT" --json >/tmp/clare-scan.json
jq . /tmp/clare-scan.json >/dev/null 2>&1 || {
  echo "JSON output invalid or jq not installed; printing raw output:" >&2
  cat /tmp/clare-scan.json
  exit 3
}

echo "env-scan smoke test passed"
