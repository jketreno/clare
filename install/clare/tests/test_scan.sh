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

# Invariant: --apply-extensions must compose with --json. It must write the
# extensions file AND keep stdout as valid JSON (apply progress goes to stderr).
# A regression where apply is skipped in JSON mode, or where its messages leak
# into stdout, must fail this test.
APPLY_DIR="$(mktemp -d)"
trap 'rm -f "$OUTPUT"; rm -rf "$APPLY_DIR"' EXIT

bash "$SCRIPT" --json --apply-extensions --vscode-dir "$APPLY_DIR/.vscode" >"$OUTPUT"

if [[ ! -f "$APPLY_DIR/.vscode/extensions.json" ]]; then
  echo "--json --apply-extensions did not write extensions.json" >&2
  exit 4
fi

"${validator[@]}" "$OUTPUT" >/dev/null 2>&1 || {
  echo "--json --apply-extensions corrupted JSON on stdout; printing raw output:" >&2
  cat "$OUTPUT"
  exit 5
}

"${validator[@]}" "$APPLY_DIR/.vscode/extensions.json" >/dev/null 2>&1 || {
  echo "written extensions.json is not valid JSON:" >&2
  cat "$APPLY_DIR/.vscode/extensions.json"
  exit 6
}

echo "env-scan smoke test passed"
