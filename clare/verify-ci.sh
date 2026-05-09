#!/usr/bin/env bash
# =============================================================================
# CLARE verify-ci.sh — Local CI/CD enforcement script
# =============================================================================
# Run this script before marking ANY AI-generated work as complete.
# It mirrors the checks your CI/CD pipeline runs, catching failures locally
# in seconds instead of waiting for the pipeline.
#
# CLARE Principle: [C] Constrained — enforced, not suggested
#
# Usage:
#   ./clare/verify-ci.sh           # Run all checks
#   ./clare/verify-ci.sh --fast    # Skip slow checks (architecture tests)
#   ./clare/verify-ci.sh --fix     # Auto-fix linting issues where possible
#
# Customization:
#   Add project-specific checks to clare/verify-local.sh (not this file).
#   This file is CLARE-owned and updated by clare-installer.sh.
#   verify-local.sh is YOUR file — it is never overwritten.
#
# AI Instructions: Run this script after generating or modifying any code.
# If it fails, fix the issues and run again. Only report work as complete
# when ALL checks pass. Never skip or bypass this script.
# =============================================================================

set -euo pipefail

SCRIPT_SELF="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAST_MODE=false
FIX_MODE=false
INCLUDE_UNTRACKED=true
FAILED_CHECKS=()

usage() {
  cat <<'EOF'
Usage: ./clare/verify-ci.sh [options]

Run local CI/CD checks and enforce CLARE constraints.

Options:
  --fast        Skip slow checks (architecture tests)
  --fix         Auto-fix lint issues where supported
  --exclude-untracked
               Check only tracked files (exclude untracked files)
  -h, --help    Show this help message and exit
EOF
}

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=true ;;
    --fix) FIX_MODE=true ;;
    --exclude-untracked) INCLUDE_UNTRACKED=false ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Run './clare/verify-ci.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

supports_color() {
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1

  if [[ -n "${FORCE_COLOR:-}" || -n "${CLICOLOR_FORCE:-}" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    return 0
  fi

  [[ -t 1 ]] || return 1

  if command -v tput >/dev/null 2>&1; then
    local colors
    colors="$(tput colors 2>/dev/null || printf '0')"
    [[ "$colors" =~ ^[0-9]+$ ]] || return 1
    ((colors >= 8)) || return 1
  fi

  return 0
}

if supports_color; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
else
  GREEN=''
  RED=''
  YELLOW=''
  BLUE=''
  NC=''
fi

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() {
  echo -e "${RED}❌ $1${NC}"
  FAILED_CHECKS+=("$1")
}
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
section() { echo -e "\n${BLUE}── $1 ──${NC}"; }

run_check() {
  local name="$1"
  local cmd="$2"
  info "Running: $cmd"
  if bash -c "$cmd"; then
    pass "$name"
    return 0
  else
    fail "$name"
    return 1
  fi
}

extract_humans_only_paths() {
  local autonomy_file="$1"

  if command -v yq >/dev/null 2>&1; then
    yq -r '.modules[]? | select(.level == "humans-only") | .path // empty' "$autonomy_file" 2>/dev/null || true
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$autonomy_file" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path

try:
  import yaml
except Exception:
  sys.exit(0)

path = Path(sys.argv[1])
try:
  data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
except Exception:
  sys.exit(0)

for module in data.get("modules", []) or []:
  if not isinstance(module, dict):
    continue
  if module.get("level") != "humans-only":
    continue
  mod_path = module.get("path")
  if isinstance(mod_path, str) and mod_path.strip():
    print(mod_path.strip())
PY
  fi
}

list_project_files_respecting_gitignore() {
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    (
      cd "$PROJECT_ROOT"
      if $INCLUDE_UNTRACKED; then
        # Tracked + untracked files, respecting .gitignore/.git/info/exclude/global excludes.
        git ls-files -co --exclude-standard
      else
        # Tracked files only.
        git ls-files
      fi
    )
  else
    find "$PROJECT_ROOT" -type f \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      ! -path "*/.venv/*" \
      ! -path "*/venv/*" \
      ! -path "*/dist/*" \
      ! -path "*/build/*" \
      ! -path "*/coverage/*" \
      | sed "s#^$PROJECT_ROOT/##"
  fi
}

is_default_ignored_path() {
  local rel_path="$1"
  case "$rel_path" in
    node_modules/* | */node_modules/* | .venv/* | */.venv/* | venv/* | */venv/* | .git/* | */.git/* | dist/* | */dist/* | build/* | */build/* | coverage/* | */coverage/*)
      return 0
      ;;
  esac
  return 1
}

path_within_scan_paths() {
  local rel_path="$1"
  local scan_paths="$2"

  [[ -z "$scan_paths" ]] && return 0

  for scan_path in $scan_paths; do
    scan_path="${scan_path#./}"
    [[ "$scan_path" == "." ]] && return 0
    [[ -z "$scan_path" ]] && continue
    if [[ "$rel_path" == "$scan_path" || "$rel_path" == "$scan_path/"* ]]; then
      return 0
    fi
  done
  return 1
}

scan_paths_exist() {
  local scan_paths="$1"

  [[ -z "$scan_paths" ]] && return 0

  for scan_path in $scan_paths; do
    scan_path="${scan_path#./}"
    [[ -z "$scan_path" || "$scan_path" == "." ]] && return 0
    [[ -e "$PROJECT_ROOT/$scan_path" ]] && return 0
  done

  return 1
}

matches_any_file_type() {
  local rel_path="$1"
  local file_types="$2"

  [[ -z "$file_types" ]] && return 0

  for ext in $file_types; do
    case "$rel_path" in
      *."$ext") return 0 ;;
    esac
  done
  return 1
}

is_extension_excluded() {
  local rel_path="$1"
  local exclude_patterns="$2"
  local base_name
  base_name="$(basename "$rel_path")"

  for pattern in $exclude_patterns; do
    case "$base_name" in
      $pattern) return 0 ;;
    esac
    case "$rel_path" in
      $pattern | $pattern/* | */$pattern | */$pattern/*) return 0 ;;
    esac
  done

  return 1
}

run_lizard_check() {
  local threshold="$1"
  local scan_paths="$2"
  local extra_flags="$3"
  local file_types="${4:-js jsx ts tsx}"
  local exclude_patterns="$5"
  local effective_scan_paths="$scan_paths"

  if ! scan_paths_exist "$scan_paths"; then
    effective_scan_paths="."
    warn "Lizard: configured paths not found (paths: $scan_paths); falling back to project root"
  fi

  local lizard_files=()
  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    is_default_ignored_path "$rel_path" && continue
    path_within_scan_paths "$rel_path" "$effective_scan_paths" || continue
    matches_any_file_type "$rel_path" "$file_types" || continue
    is_extension_excluded "$rel_path" "$exclude_patterns" && continue

    local abs_path="$PROJECT_ROOT/$rel_path"
    [[ -f "$abs_path" ]] || continue
    lizard_files+=("$abs_path")
  done < <(list_project_files_respecting_gitignore)

  if [[ ${#lizard_files[@]} -eq 0 ]]; then
    warn "Lizard: no files matched configured paths/types (paths: $effective_scan_paths, types: $file_types)"
    return 0
  fi

  local lizard_cmd=("lizard")
  [[ -n "$threshold" ]] && lizard_cmd+=("--CCN" "$threshold")
  if [[ -n "$extra_flags" ]]; then
    # Intentional word splitting for a user-specified flag string.
    # shellcheck disable=SC2206
    local extra_parts=($extra_flags)
    lizard_cmd+=("${extra_parts[@]}")
  fi
  lizard_cmd+=("${lizard_files[@]}")

  local cmd_string
  printf -v cmd_string '%q ' "${lizard_cmd[@]}"
  run_check "Lizard (cyclomatic complexity)" "$cmd_string 2>&1" || true
}

# ─── Project Type Detection ───────────────────────────────────────────────────

detect_project() {
  HAS_NODE=false
  HAS_NODE_RUNTIME=false
  HAS_PYTHON=false
  PYTHON_CMD=""
  HAS_GO=false
  HAS_RUST=false
  HAS_MAKE=false

  [[ -f "$PROJECT_ROOT/package.json" ]] && HAS_NODE=true || true
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    HAS_NODE_RUNTIME=true
  fi
  [[ -f "$PROJECT_ROOT/pyproject.toml" || -f "$PROJECT_ROOT/setup.py" || -f "$PROJECT_ROOT/requirements.txt" ]] && HAS_PYTHON=true || true
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
  fi
  [[ -f "$PROJECT_ROOT/go.mod" ]] && HAS_GO=true || true
  [[ -f "$PROJECT_ROOT/Cargo.toml" ]] && HAS_RUST=true || true
  [[ -f "$PROJECT_ROOT/Makefile" ]] && HAS_MAKE=true || true
}

# ─── Check Groups ─────────────────────────────────────────────────────────────

check_build() {
  section "Build"

  if $HAS_NODE; then
    if ! $HAS_NODE_RUNTIME; then
      warn "package.json found but node/npm are not installed; skipping Node.js build checks"
    else
      local build_script
      build_script=$(node -e "const p=require('$PROJECT_ROOT/package.json'); console.log(p.scripts && p.scripts.build ? 'build' : '')" 2>/dev/null || echo "")
      if [[ -n "$build_script" ]]; then
        run_check "npm build" "cd '$PROJECT_ROOT' && npm run build 2>&1" || true
      else
        info "No build script found in package.json — skipping"
      fi
    fi
  fi

  if $HAS_PYTHON; then
    if [[ -n "$PYTHON_CMD" ]]; then
      run_check "Python syntax check" "$PYTHON_CMD -m compileall '$PROJECT_ROOT' -q 2>&1 | head -20" || true
    else
      warn "Python project detected but no Python interpreter found; skipping syntax check"
    fi
  fi

  if $HAS_GO; then
    run_check "Go build" "cd '$PROJECT_ROOT' && go build ./... 2>&1" || true
  fi

  if $HAS_RUST; then
    run_check "Cargo build" "cd '$PROJECT_ROOT' && cargo build 2>&1" || true
  fi
}

check_lint() {
  section "Linting"

  if $HAS_NODE; then
    if ! $HAS_NODE_RUNTIME; then
      warn "package.json found but node/npm are not installed; skipping Node.js lint/type checks"
    else
      local fix_flag=""
      $FIX_MODE && fix_flag="--fix"

      if node -e "require.resolve('eslint/package.json', { paths: ['$PROJECT_ROOT'] })" 2>/dev/null; then
        run_check "ESLint" "cd '$PROJECT_ROOT' && npx eslint . $fix_flag 2>&1" || true
      elif [[ -f "$PROJECT_ROOT/.eslintrc.js" || -f "$PROJECT_ROOT/.eslintrc.json" || -f "$PROJECT_ROOT/eslint.config.js" ]]; then
        warn "ESLint config found but ESLint not installed. Run: npm install"
      fi

      if node -e "require.resolve('prettier/package.json', { paths: ['$PROJECT_ROOT'] })" 2>/dev/null; then
        local prettier_flag="--check"
        $FIX_MODE && prettier_flag="--write"
        run_check "Prettier" "cd '$PROJECT_ROOT' && npx prettier $prettier_flag . 2>&1" || true
      fi

      if node -e "require.resolve('typescript/package.json', { paths: ['$PROJECT_ROOT'] })" 2>/dev/null; then
        run_check "TypeScript (no-emit)" "cd '$PROJECT_ROOT' && npx tsc --noEmit 2>&1" || true
      fi
    fi
  fi

  if $HAS_PYTHON; then
    if command -v ruff &>/dev/null; then
      local fix_flag=""
      $FIX_MODE && fix_flag="--fix"
      run_check "Ruff" "cd '$PROJECT_ROOT' && ruff check $fix_flag . 2>&1" || true
    elif command -v flake8 &>/dev/null; then
      run_check "Flake8" "cd '$PROJECT_ROOT' && flake8 . 2>&1" || true
    fi

    if command -v mypy &>/dev/null; then
      run_check "Mypy" "cd '$PROJECT_ROOT' && mypy . 2>&1" || true
    fi
  fi

  if $HAS_GO; then
    run_check "Go vet" "cd '$PROJECT_ROOT' && go vet ./... 2>&1" || true
    if command -v golint &>/dev/null; then
      run_check "Golint" "cd '$PROJECT_ROOT' && golint ./... 2>&1" || true
    fi
  fi
}

check_tests() {
  section "Tests"

  if $HAS_NODE; then
    if ! $HAS_NODE_RUNTIME; then
      warn "package.json found but node/npm are not installed; skipping Node.js test checks"
    else
      local test_script
      test_script=$(node -e "const p=require('$PROJECT_ROOT/package.json'); console.log(p.scripts && p.scripts.test ? 'test' : '')" 2>/dev/null || echo "")
      if [[ -n "$test_script" ]]; then
        run_check "npm test" "cd '$PROJECT_ROOT' && npm test 2>&1" || true
      fi
    fi
  fi

  if $HAS_PYTHON; then
    if command -v pytest &>/dev/null; then
      run_check "pytest" "cd '$PROJECT_ROOT' && pytest --tb=short -q 2>&1" || true
    fi
  fi

  if $HAS_GO; then
    run_check "Go test" "cd '$PROJECT_ROOT' && go test ./... 2>&1" || true
  fi

  if $HAS_RUST; then
    run_check "Cargo test" "cd '$PROJECT_ROOT' && cargo test 2>&1" || true
  fi
}

check_architecture() {
  section "Architecture Tests"

  if $FAST_MODE; then
    warn "Architecture tests skipped (--fast mode)"
    return 0
  fi

  if $HAS_NODE; then
    if ! $HAS_NODE_RUNTIME; then
      warn "package.json found but node/npm are not installed; skipping Node.js architecture checks"
    else
      local arch_script
      arch_script=$(node -e "const p=require('$PROJECT_ROOT/package.json'); console.log(p.scripts && p.scripts['test:architecture'] ? 'test:architecture' : '')" 2>/dev/null || echo "")
      if [[ -n "$arch_script" ]]; then
        run_check "Architecture tests" "cd '$PROJECT_ROOT' && npm run test:architecture 2>&1" || true
      fi
    fi
  fi

  if $HAS_PYTHON; then
    if [[ -d "$PROJECT_ROOT/tests/architecture" ]]; then
      run_check "Architecture tests (pytest)" "cd '$PROJECT_ROOT' && pytest tests/architecture/ --tb=short -q 2>&1" || true
    fi
  fi
}

check_autonomy() {
  section "CLARE Autonomy Boundaries"

  local autonomy_file="$PROJECT_ROOT/clare/autonomy.yml"
  if [[ -f "$autonomy_file" ]]; then
    pass "autonomy.yml found"

    # Check for humans-only paths — warn if git staging area contains any
    if command -v git &>/dev/null && git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null; then
      local staged_files
      staged_files=$(git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null || echo "")
      if [[ -n "$staged_files" ]]; then
        while IFS= read -r humans_path; do
          [[ -z "$humans_path" || "$humans_path" == "*" ]] && continue
          while IFS= read -r staged; do
            [[ -z "$staged" ]] && continue
            if [[ "$staged" == "$humans_path" || "$staged" == "$humans_path/"* ]]; then
              warn "Staged file matches humans-only path: $humans_path ($staged)"
              warn "Review clare/autonomy.yml before committing AI-generated changes to this path."
            fi
          done <<<"$staged_files"
        done < <(extract_humans_only_paths "$autonomy_file")
      fi
    fi
  else
    warn "clare/autonomy.yml not found — run the CLARE installer to configure CLARE"
  fi
}

# ─── Extensions ──────────────────────────────────────────────────────────────
# Optional tool extensions configured in clare/extensions.yml.
# Each extension wraps an external tool. If enabled but not installed,
# verify-ci.sh fails with install instructions (never auto-installs).

check_extensions() {
  local extensions_file="$PROJECT_ROOT/clare/extensions.yml"
  [[ -f "$extensions_file" ]] || return 0

  # Parse enabled extensions from YAML (lightweight awk — no yq dependency)
  local in_extension=false
  local ext_name="" ext_enabled="" ext_command="" ext_install="" ext_url=""
  local ext_threshold="" ext_paths="" ext_extra="" ext_file_types="" ext_exclude=""
  local ext_count_comments="true"

  process_pending_extension() {
    if [[ -n "$ext_name" && "$ext_enabled" == "true" ]]; then
      run_extension "$ext_name" "$ext_command" "$ext_install" "$ext_url" \
        "$ext_threshold" "$ext_paths" "$ext_extra" \
        "$ext_file_types" "$ext_exclude" "$ext_count_comments"
    fi
  }

  while IFS= read -r line; do
    # Detect start of a new extension block
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
      process_pending_extension
      ext_name="${BASH_REMATCH[1]}"
      ext_name="${ext_name#\"}"
      ext_name="${ext_name%\"}"
      ext_enabled=""
      ext_command=""
      ext_install=""
      ext_url=""
      ext_threshold=""
      ext_paths=""
      ext_extra=""
      ext_file_types=""
      ext_exclude=""
      ext_count_comments="true"
      in_extension=true
      continue
    fi

    $in_extension || continue

    if [[ "$line" =~ ^[[:space:]]*enabled:[[:space:]]*(.*) ]]; then
      ext_enabled="${BASH_REMATCH[1]}"
      ext_enabled="${ext_enabled#\"}"
      ext_enabled="${ext_enabled%\"}"
    elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*(.*) ]]; then
      ext_command="${BASH_REMATCH[1]}"
      ext_command="${ext_command#\"}"
      ext_command="${ext_command%\"}"
    elif [[ "$line" =~ ^[[:space:]]*install_hint:[[:space:]]*(.*) ]]; then
      ext_install="${BASH_REMATCH[1]}"
      ext_install="${ext_install#\"}"
      ext_install="${ext_install%\"}"
    elif [[ "$line" =~ ^[[:space:]]*project_url:[[:space:]]*(.*) ]]; then
      ext_url="${BASH_REMATCH[1]}"
      ext_url="${ext_url#\"}"
      ext_url="${ext_url%\"}"
    elif [[ "$line" =~ ^[[:space:]]*threshold:[[:space:]]*(.*) ]]; then
      ext_threshold="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*paths:[[:space:]]*(.*) ]]; then
      ext_paths="${BASH_REMATCH[1]}"
      ext_paths="${ext_paths#\"}"
      ext_paths="${ext_paths%\"}"
    elif [[ "$line" =~ ^[[:space:]]*extra_flags:[[:space:]]*(.*) ]]; then
      ext_extra="${BASH_REMATCH[1]}"
      ext_extra="${ext_extra#\"}"
      ext_extra="${ext_extra%\"}"
    elif [[ "$line" =~ ^[[:space:]]*file_types:[[:space:]]*(.*) ]]; then
      ext_file_types="${BASH_REMATCH[1]}"
      ext_file_types="${ext_file_types#\"}"
      ext_file_types="${ext_file_types%\"}"
    elif [[ "$line" =~ ^[[:space:]]*exclude:[[:space:]]*(.*) ]]; then
      ext_exclude="${BASH_REMATCH[1]}"
      ext_exclude="${ext_exclude#\"}"
      ext_exclude="${ext_exclude%\"}"
    elif [[ "$line" =~ ^[[:space:]]*count_comments:[[:space:]]*(.*) ]]; then
      ext_count_comments="${BASH_REMATCH[1]}"
      ext_count_comments="${ext_count_comments#\"}"
      ext_count_comments="${ext_count_comments%\"}"
    fi
  done <"$extensions_file"

  # Process the last extension
  process_pending_extension
}

run_extension() {
  local name="$1" command="$2" install_hint="$3" url="$4"
  local threshold="$5" paths="$6" extra="$7"
  local file_types="${8:-}" exclude="${9:-}" count_comments="${10:-true}"

  section "Extension: $name"

  # Check if the tool is installed
  if ! command -v "$command" &>/dev/null; then
    fail "Extension '$name': '$command' not found"
    echo ""
    echo -e "${RED}   '$name' is enabled in clare/extensions.yml but '$command' is not installed.${NC}"
    echo ""
    echo -e "${RED}   To install:  ${YELLOW}${install_hint}${NC}"
    [[ -n "$url" ]] && echo -e "${RED}   Project:     ${YELLOW}${url}${NC}"
    echo ""
    echo -e "${RED}   To disable this extension:${NC}"
    echo -e "${RED}     Edit clare/extensions.yml and set enabled: false for '$name'${NC}"
    echo ""
    return 1
  fi

  # Build and run the extension command
  case "$name" in
    lizard)
      run_lizard_check "$threshold" "$paths" "$extra" "$file_types" "$exclude"
      ;;
    file-size)
      run_file_size_check "$threshold" "$paths" "$file_types" "$exclude" "$count_comments"
      ;;
    *)
      warn "Unknown extension '$name' — skipping (no built-in handler)"
      warn "Add a handler in verify-ci.sh or use verify-local.sh for custom checks"
      ;;
  esac
}

# line_comment_prefix ext
#   Returns the line-comment prefix for a file extension, or empty string if
#   the language uses only block comments (e.g. CSS) or is unrecognised.
line_comment_prefix() {
  local ext="$1"
  case "$ext" in
    js | jsx | ts | tsx | java | kt | kts | scala | go | rs | swift | c | cc | cpp | cxx | h | hpp | cs | dart | groovy | gradle)
      echo "//"
      ;;
    py | rb | sh | bash | zsh | fish | r | pl | perl | tcl | yaml | yml | toml | makefile | mk | dockerfile)
      echo "#"
      ;;
    lua)
      echo "--"
      ;;
    *)
      echo ""
      ;;
  esac
}

# count_code_lines filepath [count_comments]
#   Counts lines in a file. When count_comments=false, pure comment-only lines
#   (leading whitespace + comment prefix + anything) are excluded. A line that
#   has code followed by a comment is NOT excluded. Blank lines are always
#   counted. Block comments spanning multiple lines are not stripped.
count_code_lines() {
  local filepath="$1"
  local count_comments="${2:-true}"

  if [[ "$count_comments" == "true" ]]; then
    wc -l <"$filepath"
    return
  fi

  local ext="${filepath##*.}"
  ext="${ext,,}"
  local prefix
  prefix="$(line_comment_prefix "$ext")"

  if [[ -z "$prefix" ]]; then
    # No known line-comment prefix for this type; count all lines
    wc -l <"$filepath"
    return
  fi

  # Escape prefix for use in sed (// → \/\/)
  local escaped_prefix
  escaped_prefix="$(printf '%s' "$prefix" | sed 's/[\/&]/\\&/g')"

  # Strip lines that are ONLY a comment: optional whitespace, then the prefix
  sed "/^[[:space:]]*${escaped_prefix}/d" "$filepath" | wc -l
}

run_file_size_check() {
  local max_lines="${1:-300}"
  local scan_paths="${2:-src}"
  local file_types="${3:-js ts tsx jsx}"
  local exclude_patterns="${4:-}"
  local count_comments="${5:-true}"
  local effective_scan_paths="$scan_paths"
  local oversized_files=()
  local oversized_counts=()
  local checked_files=0

  if ! scan_paths_exist "$scan_paths"; then
    effective_scan_paths="."
    warn "File size check: configured paths not found (paths: $scan_paths); falling back to project root"
  fi

  local count_label="lines"
  [[ "$count_comments" == "false" ]] && count_label="non-comment lines"

  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    is_default_ignored_path "$rel_path" && continue
    path_within_scan_paths "$rel_path" "$effective_scan_paths" || continue
    matches_any_file_type "$rel_path" "$file_types" || continue
    is_extension_excluded "$rel_path" "$exclude_patterns" && continue

    local filepath="$PROJECT_ROOT/$rel_path"
    [[ -f "$filepath" ]] || continue

    local line_count
    line_count=$(count_code_lines "$filepath" "$count_comments")
    ((checked_files += 1))

    if [[ "$line_count" -gt "$max_lines" ]]; then
      oversized_files+=("$rel_path")
      oversized_counts+=("$line_count")
    fi
  done < <(list_project_files_respecting_gitignore)

  if [[ "$checked_files" -eq 0 ]]; then
    warn "File size check: no files matched configured paths/types (paths: $effective_scan_paths, types: $file_types)"
    return 0
  fi

  if [[ ${#oversized_files[@]} -eq 0 ]]; then
    pass "File size (all files under $max_lines $count_label)"
  else
    fail "File size (${#oversized_files[@]} file(s) exceed $max_lines $count_label)"
    echo ""
    for i in "${!oversized_files[@]}"; do
      echo -e "${RED}   ${oversized_files[$i]}: ${oversized_counts[$i]} $count_label (max: $max_lines)${NC}"
    done
    echo ""
    echo -e "${YELLOW}   Split large files into smaller, focused modules.${NC}"
    echo -e "${YELLOW}   Adjust the threshold in clare/extensions.yml if needed.${NC}"
    echo ""
  fi
}

# ─── Local Project Checks ────────────────────────────────────────────────────
# Source verify-local.sh if it exists. That file is project-owned (never
# overwritten by CLARE updates) and can call run_check, pass, fail, info,
# warn, section, and read FAST_MODE / FIX_MODE / PROJECT_ROOT.

source_local_checks() {
  if [[ -f "$SCRIPT_DIR/verify-local.sh" ]]; then
    section "Project-Specific Checks (verify-local.sh)"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/verify-local.sh"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo -e "${BLUE}════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  CLARE — Local CI/CD Verification          ${NC}"
  echo -e "${BLUE}════════════════════════════════════════════${NC}"

  cd "$PROJECT_ROOT"
  detect_project

  info "Project root: $PROJECT_ROOT"
  $HAS_NODE && info "Detected: Node.js"
  $HAS_PYTHON && info "Detected: Python"
  $HAS_GO && info "Detected: Go"
  $HAS_RUST && info "Detected: Rust"
  $FAST_MODE && warn "Fast mode: architecture tests skipped"
  $FIX_MODE && warn "Fix mode: auto-fixing lint issues where possible"
  if $INCLUDE_UNTRACKED; then
    info "File scanning includes untracked files (use --exclude-untracked to limit to tracked files)"
  else
    info "File scanning excludes untracked files"
  fi

  check_build
  check_lint
  check_tests
  check_architecture
  check_autonomy
  check_extensions
  source_local_checks

  echo ""
  echo -e "${BLUE}════════════════════════════════════════════${NC}"
  if [[ ${#FAILED_CHECKS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ All checks passed — work is complete.${NC}"
    echo -e "${GREEN}   No further terminal input is required; you can proceed to commit.${NC}"
    echo ""
    exit 0
  else
    echo -e "${RED}❌ ${#FAILED_CHECKS[@]} check(s) failed:${NC}"
    for check in "${FAILED_CHECKS[@]}"; do
      echo -e "${RED}   • $check${NC}"
    done
    echo ""
    echo -e "${RED}   Fix the issues above and run this script again.${NC}"
    echo -e "${RED}   Work is NOT complete until all checks pass.${NC}"
    exit 1
  fi
}

main "$@"
