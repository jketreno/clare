#!/usr/bin/env bash
# =============================================================================
# verify-local.sh — Project-specific checks for CLARE repository compliance
# =============================================================================
# This file is sourced by clare/verify-ci.sh.
# It enforces shell script quality gates that are project-owned:
#   - shellcheck on tracked *.sh files
#   - shfmt formatting check on tracked *.sh files
#   - bash syntax check on tracked *.sh files
#   - script guardrails for top-level scripts/*.sh
# =============================================================================

set -euo pipefail

section "Shell Script Compliance"

collect_shell_files() {
  local out_ref="$1"
  eval "$out_ref=()"

  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r rel_path; do
      [[ -z "$rel_path" ]] && continue
      [[ -f "$PROJECT_ROOT/$rel_path" ]] || continue
      eval "$out_ref+=(\"$rel_path\")"
    done < <(cd "$PROJECT_ROOT" && git ls-files '*.sh')
    return 0
  fi

  while IFS= read -r abs_path; do
    [[ -z "$abs_path" ]] && continue
    local rel_path="${abs_path#"$PROJECT_ROOT/"}"
    eval "$out_ref+=(\"$rel_path\")"
  done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -print)
}

collect_humans_only_paths() {
  local out_ref="$1"
  eval "$out_ref=()"

  local autonomy_file
  autonomy_file="$PROJECT_ROOT/clare/autonomy.yml"
  [[ -f "$autonomy_file" ]] || return 0

  if command -v yq >/dev/null 2>&1; then
    while IFS= read -r path_rule; do
      [[ -n "$path_rule" ]] && eval "$out_ref+=(\"$path_rule\")"
    done < <(yq -r '.modules[]? | select(.level == "humans-only") | .path // empty' "$autonomy_file" 2>/dev/null || true)
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r path_rule; do
      [[ -n "$path_rule" ]] && eval "$out_ref+=(\"$path_rule\")"
    done < <(
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
    )
  fi
}

is_humans_only_match() {
  local rel_path="$1"
  shift
  local path_rule
  for path_rule in "$@"; do
    [[ -z "$path_rule" || "$path_rule" == "*" ]] && continue
    if [[ "$rel_path" == "$path_rule" || "$rel_path" == "$path_rule/"* ]]; then
      return 0
    fi
  done
  return 1
}

is_required_shell_check_path() {
  local rel_path="$1"

  if [[ "$(basename "$rel_path")" == "verify-ci.sh" ]]; then
    return 0
  fi

  return 1
}

run_shellcheck_check() {
  local -a abs_files=("$@")

  if ! command -v shellcheck >/dev/null 2>&1; then
    fail "Shellcheck (not installed; install with your package manager)"
    return 1
  fi

  local output_file
  if ! output_file="$(mktemp)"; then
    fail "Shellcheck (failed to create temporary output file)"
    return 1
  fi
  if shellcheck -x --severity=error "${abs_files[@]}" >"$output_file" 2>&1; then
    pass "Shellcheck"
  else
    fail "Shellcheck"
    cat "$output_file"
  fi
  rm -f "$output_file"
}

run_shfmt_check() {
  local -a abs_files=("$@")

  if ! command -v shfmt >/dev/null 2>&1; then
    fail "shfmt (not installed; install with your package manager)"
    return 1
  fi

  if [[ "${FIX_MODE:-false}" == "true" ]]; then
    local shfmt_flags="${SHFMT_FLAGS:--i 2 -ci -bn -ln=bash}"
    # Intentional split for env-configurable shfmt flags.
    # shellcheck disable=SC2206
    local shfmt_args=($shfmt_flags)
    if shfmt "${shfmt_args[@]}" -w "${abs_files[@]}"; then
      pass "shfmt (auto-fixed)"
      return 0
    fi
    fail "shfmt (auto-fix failed)"
    return 1
  fi

  local output_file
  if ! output_file="$(mktemp)"; then
    fail "shfmt (failed to create temporary output file)"
    return 1
  fi
  local shfmt_flags="${SHFMT_FLAGS:--i 2 -ci -bn -ln=bash}"
  # Intentional split for env-configurable shfmt flags.
  # shellcheck disable=SC2206
  local shfmt_args=($shfmt_flags)
  if shfmt "${shfmt_args[@]}" -d "${abs_files[@]}" >"$output_file" 2>&1; then
    pass "shfmt"
  else
    fail "shfmt"
    cat "$output_file"
  fi
  rm -f "$output_file"
}

run_bash_syntax_check() {
  local -a abs_files=("$@")
  local has_error=false

  for file_path in "${abs_files[@]}"; do
    if ! bash -n "$file_path"; then
      echo "Syntax error: ${file_path#"$PROJECT_ROOT/"}" >&2
      has_error=true
    fi
  done

  if [[ "$has_error" == "true" ]]; then
    fail "Bash syntax"
  else
    pass "Bash syntax"
  fi
}

run_scripts_guardrails_check() {
  local -a scripts_files=("$@")
  local has_error=false

  for abs_path in "${scripts_files[@]}"; do
    local rel_path
    rel_path="${abs_path#"$PROJECT_ROOT/"}"

    if [[ ! -x "$abs_path" ]]; then
      echo "Not executable: $rel_path" >&2
      has_error=true
    fi

    local first_line
    first_line="$(head -n 1 "$abs_path")"
    if [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
      echo "Invalid shebang in $rel_path (expected #!/usr/bin/env bash)" >&2
      has_error=true
    fi

    if ! grep -Eq '^set -euo pipefail$' "$abs_path"; then
      echo "Missing safety flags in $rel_path (expected set -euo pipefail)" >&2
      has_error=true
    fi
  done

  if [[ "$has_error" == "true" ]]; then
    fail "scripts/ guardrails (shebang, safety flags, executable)"
  else
    pass "scripts/ guardrails (shebang, safety flags, executable)"
  fi
}

run_forbidden_pipeline_check() {
  local -a rel_files=("$@")
  local has_error=false
  local forbidden_pattern='curl[[:space:]]*\|[[:space:]]*bash|wget[[:space:]]*\|[[:space:]]*bash|curl[^\n|]*\|[[:space:]]*bash|wget[^\n|]*\|[[:space:]]*bash|source[[:space:]]*<\([[:space:]]*(curl|wget)|eval[[:space:]]*\$\([[:space:]]*(curl|wget)'

  if command -v rg >/dev/null 2>&1; then
    local match_output
    match_output="$(cd "$PROJECT_ROOT" && rg -n --no-heading "$forbidden_pattern" -- "${rel_files[@]}" || true)"
    if [[ -n "$match_output" ]]; then
      echo "$match_output" >&2
      has_error=true
    fi
  else
    local rel_path
    for rel_path in "${rel_files[@]}"; do
      if grep -En "$forbidden_pattern" "$PROJECT_ROOT/$rel_path" >/dev/null 2>&1; then
        grep -En "$forbidden_pattern" "$PROJECT_ROOT/$rel_path" >&2 || true
        has_error=true
      fi
    done
  fi

  if [[ "$has_error" == "true" ]]; then
    fail "Forbidden pipe-to-shell patterns"
  else
    pass "Forbidden pipe-to-shell patterns"
  fi
}

shell_rel_files=()
collect_shell_files shell_rel_files
humans_only_paths=()
collect_humans_only_paths humans_only_paths

filtered_rel_files=()
for rel_path in "${shell_rel_files[@]}"; do
  if is_humans_only_match "$rel_path" "${humans_only_paths[@]}" && ! is_required_shell_check_path "$rel_path"; then
    info "Skipping humans-only shell file: $rel_path"
    continue
  fi
  filtered_rel_files+=("$rel_path")
done

shell_rel_files=("${filtered_rel_files[@]}")

if [[ ${#shell_rel_files[@]} -eq 0 ]]; then
  warn "No tracked shell scripts found; skipping shell compliance checks"
else
  shell_abs_files=()
  for rel_path in "${shell_rel_files[@]}"; do
    shell_abs_files+=("$PROJECT_ROOT/$rel_path")
  done

  run_shellcheck_check "${shell_abs_files[@]}"
  run_shfmt_check "${shell_abs_files[@]}"
  run_bash_syntax_check "${shell_abs_files[@]}"

  scripts_abs_files=()
  for rel_path in "${shell_rel_files[@]}"; do
    if [[ "$rel_path" == scripts/*.sh ]]; then
      scripts_abs_files+=("$PROJECT_ROOT/$rel_path")
    fi
  done

  if [[ ${#scripts_abs_files[@]} -eq 0 ]]; then
    warn "No top-level scripts/*.sh files found for guardrail checks"
  else
    run_scripts_guardrails_check "${scripts_abs_files[@]}"
  fi

  run_forbidden_pipeline_check "${shell_rel_files[@]}"
fi
