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

python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
for key in ('detectedSurfaces', 'verifiedSurfaces', 'coverageGaps', 'agentPrompts'):
    if key not in data:
        raise SystemExit(f'missing readiness key: {key}')
if not isinstance(data['agentPrompts'], list) or not data['agentPrompts']:
    raise SystemExit('agentPrompts must include at least one prompt')
PY

FIXTURE="$(mktemp -d)"
trap 'rm -f "$OUTPUT"; [[ -n "${APPLY_DIR:-}" ]] && rm -rf "$APPLY_DIR"; rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/frontend" "$FIXTURE/.github/workflows"
git -C "$FIXTURE" init -q
cat >"$FIXTURE/frontend/package.json" <<'JSON'
{"scripts":{"build":"vite build","lint":"eslint src","test":"vitest"},"devDependencies":{"eslint":"^8.0.0"}}
JSON
cat >"$FIXTURE/Makefile" <<'MAKE'
frontend:
	npm --prefix frontend run build
prod:
	docker compose up app
MAKE
cat >"$FIXTURE/docker-compose.yml" <<'YAML'
services:
  app:
    build: .
  frontend:
    build: ./frontend
YAML
touch "$FIXTURE/pyproject.toml" "$FIXTURE/go.mod" "$FIXTURE/Cargo.toml" "$FIXTURE/.github/workflows/ci.yml"
(cd "$FIXTURE" && bash "$SCRIPT" --json >"$OUTPUT")
"${validator[@]}" "$OUTPUT" >/dev/null 2>&1 || {
  echo "fixture JSON output invalid; printing raw output:" >&2
  cat "$OUTPUT"
  exit 7
}
python3 - "$OUTPUT" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
surfaces = data.get('detectedSurfaces', [])
gaps = data.get('coverageGaps', [])
required = {
    ('node-script', 'build'),
    ('make-target', 'frontend'),
    ('docker-compose-service', 'frontend'),
    ('python-project', 'pyproject.toml'),
    ('go-module', 'go test/build'),
    ('rust-crate', 'cargo test/build'),
    ('github-actions', 'ci.yml'),
}
found = {(item.get('kind'), item.get('name')) for item in surfaces}
missing = sorted(required - found)
if missing:
    raise SystemExit(f'missing detected surfaces: {missing}')
if not gaps:
    raise SystemExit('expected fixture coverage gaps')
if 'deployment' not in data['agentPrompts'][0]['prompt'].lower():
    raise SystemExit('agent prompt should mention deployment')
PY

# Invariant: --apply-extensions must compose with --json. It must write the
# extensions file AND keep stdout as valid JSON (apply progress goes to stderr).
# A regression where apply is skipped in JSON mode, or where its messages leak
# into stdout, must fail this test.
APPLY_DIR="$(mktemp -d)"
trap 'rm -f "$OUTPUT"; rm -rf "$APPLY_DIR" "$FIXTURE"' EXIT

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
