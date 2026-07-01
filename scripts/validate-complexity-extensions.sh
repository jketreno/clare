#!/usr/bin/env bash
# =============================================================================
# validate-complexity-extensions.sh — Fixture validation for complexity checks
# =============================================================================
# Purpose:
#   Validate CLARE language-specific complexity extensions with deterministic
#   fail/pass fixtures for TypeScript (ESLint), Go (golangci-lint), and Python
#   (complexipy).
#
# Usage:
#   ./scripts/validate-complexity-extensions.sh
#
# Notes:
#   - Skips a language if its required CLI is unavailable.
#   - Runs verify-ci.sh inside temporary fixture projects.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_SCRIPT="$REPO_ROOT/clare/verify-ci.sh"
AUTONOMY_FILE="$REPO_ROOT/clare/autonomy.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; }
warn() { echo -e "${YELLOW}SKIP${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
info() { echo -e "${BLUE}INFO${NC} $1"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

copy_core_clare_files() {
  local project_root="$1"
  mkdir -p "$project_root/clare"
  cp "$VERIFY_SCRIPT" "$project_root/clare/verify-ci.sh"
  cp "$AUTONOMY_FILE" "$project_root/clare/autonomy.yml"
  chmod +x "$project_root/clare/verify-ci.sh"
}

write_extensions_file() {
  local project_root="$1"
  local extension_name="$2"
  local command_name="$3"
  local threshold="$4"
  local file_types="$5"
  local paths="${6:-src}"

  cat >"$project_root/clare/extensions.yml" <<EOF
extensions:
  - name: $extension_name
    enabled: true
    description: "fixture"
    command: "$command_name"
    install_hint: "install"
    project_url: ""
    options:
      threshold: $threshold
      file_types: "$file_types"
      paths: "$paths"
      exclude: ""
      extra_flags: ""
  - name: file-size
    enabled: false
    description: "disabled"
    command: "wc"
    install_hint: "built-in"
    project_url: ""
    options:
      threshold: 300
      file_types: "js ts tsx jsx py go"
      paths: "src"
      exclude: ""
      count_comments: true
EOF
}

run_verify_case() {
  local project_root="$1"
  local expected_exit="$2"
  local label="$3"

  local output_file="$project_root/verify-output.txt"
  local status=0

  set +e
  (
    cd "$project_root"
    ./clare/verify-ci.sh --exclude-untracked
  ) >"$output_file" 2>&1
  status=$?
  set -e

  if [[ "$status" -eq "$expected_exit" ]]; then
    pass "$label"
    return 0
  fi

  fail "$label (expected exit $expected_exit, got $status)"
  tail -n 40 "$output_file" | sed 's/^/    /'
  return 1
}

validate_typescript() {
  if ! command -v npx >/dev/null 2>&1; then
    warn "TypeScript validation (npx not installed)"
    return 0
  fi

  if ! (cd "$REPO_ROOT" && npx --no-install eslint --version >/dev/null 2>&1); then
    warn "TypeScript validation (eslint not available via npx --no-install)"
    return 0
  fi

  # The fixtures symlink $REPO_ROOT/node_modules so verify-ci.sh can resolve
  # eslint from the temp project. Without it the symlink dangles and resolution
  # fails — skip cleanly (matching the complexipy not-runnable guard below)
  # rather than reporting a confusing failure.
  if [[ ! -d "$REPO_ROOT/node_modules" ]]; then
    warn "TypeScript validation (node_modules missing; run 'npm install' first)"
    return 0
  fi

  info "Validating TypeScript complexity extension"

  local fail_project="$TMP_ROOT/ts-fail"
  mkdir -p "$fail_project/src"
  copy_core_clare_files "$fail_project"
  ln -s "$REPO_ROOT/node_modules" "$fail_project/node_modules"
  write_extensions_file "$fail_project" "eslint-complexity" "npx" "1" "js"
  cat >"$fail_project/eslint.config.js" <<'EOF'
module.exports = [
  {
    files: ["**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
    },
    rules: {},
  },
];
EOF
  cat >"$fail_project/src/sample.js" <<'EOF'
export function hard(a, b, c) {
  if (a) {
    return 1;
  }
  if (b) {
    return 2;
  }
  if (c) {
    return 3;
  }
  return 0;
}
EOF
  run_verify_case "$fail_project" 1 "TypeScript fixture fails above threshold"

  local pass_project="$TMP_ROOT/ts-pass"
  mkdir -p "$pass_project/src"
  copy_core_clare_files "$pass_project"
  ln -s "$REPO_ROOT/node_modules" "$pass_project/node_modules"
  write_extensions_file "$pass_project" "eslint-complexity" "npx" "5" "js"
  cat >"$pass_project/eslint.config.js" <<'EOF'
module.exports = [
  {
    files: ["**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
    },
    rules: {},
  },
];
EOF
  cat >"$pass_project/src/sample.js" <<'EOF'
export function easy(a) {
  if (a) {
    return 1;
  }
  return 0;
}
EOF
  run_verify_case "$pass_project" 0 "TypeScript fixture passes at safe threshold"

  local scoped_project="$TMP_ROOT/ts-scoped"
  mkdir -p "$scoped_project/frontend/src"
  copy_core_clare_files "$scoped_project"
  ln -s "$REPO_ROOT/node_modules" "$scoped_project/frontend/node_modules"
  write_extensions_file "$scoped_project" "eslint-complexity" "npx" "99" "js" "frontend/src"
  cat >"$scoped_project/frontend/package.json" <<'EOF'
{"devDependencies":{"eslint":"^8.0.0"}}
EOF
  cat >"$scoped_project/frontend/eslint.config.js" <<'EOF'
module.exports = [
  {
    files: ["**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
    },
    rules: {
      "no-restricted-syntax": ["error", "IfStatement"],
    },
  },
];
EOF
  cat >"$scoped_project/frontend/src/sample.js" <<'EOF'
export function scoped(a) {
  if (a) {
    return 1;
  }
  return 0;
}
EOF
  run_verify_case "$scoped_project" 1 "TypeScript extension honors nested project ESLint config"
}

validate_go() {
  if ! command -v golangci-lint >/dev/null 2>&1; then
    warn "Go validation (golangci-lint not installed)"
    return 0
  fi

  info "Validating Go complexity extension"

  local fail_project="$TMP_ROOT/go-fail"
  mkdir -p "$fail_project/src"
  copy_core_clare_files "$fail_project"
  write_extensions_file "$fail_project" "golangci-lint-complexity" "golangci-lint" "1" "go"
  cat >"$fail_project/go.mod" <<'EOF'
module fixture.example/go

go 1.22
EOF
  cat >"$fail_project/src/sample.go" <<'EOF'
package sample

func Hard(a bool, b bool, c bool) int {
	if a {
		return 1
	}
	if b {
		return 2
	}
	if c {
		return 3
	}
	return 0
}
EOF
  run_verify_case "$fail_project" 1 "Go fixture fails above threshold"

  local pass_project="$TMP_ROOT/go-pass"
  mkdir -p "$pass_project/src"
  copy_core_clare_files "$pass_project"
  write_extensions_file "$pass_project" "golangci-lint-complexity" "golangci-lint" "5" "go"
  cat >"$pass_project/go.mod" <<'EOF'
module fixture.example/go

go 1.22
EOF
  cat >"$pass_project/src/sample.go" <<'EOF'
package sample

func Easy(a bool) int {
	if a {
		return 1
	}
	return 0
}
EOF
  run_verify_case "$pass_project" 0 "Go fixture passes at safe threshold"
}

validate_python() {
  if ! command -v complexipy >/dev/null 2>&1; then
    warn "Python validation (complexipy not installed)"
    return 0
  fi
  if ! complexipy --help >/dev/null 2>&1; then
    warn "Python validation (complexipy is installed but not runnable)"
    return 0
  fi

  info "Validating Python complexity extension"

  local fail_project="$TMP_ROOT/py-fail"
  mkdir -p "$fail_project/src"
  copy_core_clare_files "$fail_project"
  write_extensions_file "$fail_project" "complexipy-complexity" "complexipy" "1" "py"
  cat >"$fail_project/src/sample.py" <<'EOF'
def hard(a, b, c):
    if a:
        return 1
    if b:
        return 2
    if c:
        return 3
    return 0
EOF
  run_verify_case "$fail_project" 1 "Python fixture fails above threshold"

  local pass_project="$TMP_ROOT/py-pass"
  mkdir -p "$pass_project/src"
  copy_core_clare_files "$pass_project"
  write_extensions_file "$pass_project" "complexipy-complexity" "complexipy" "5" "py"
  cat >"$pass_project/src/sample.py" <<'EOF'
def easy(a):
    if a:
        return 1
    return 0
EOF
  run_verify_case "$pass_project" 0 "Python fixture passes at safe threshold"
}

main() {
  info "Running fixture validation for complexity extensions"

  validate_typescript
  validate_go
  validate_python

  pass "Fixture validation complete"
}

main "$@"
