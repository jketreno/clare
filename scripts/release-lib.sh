#!/usr/bin/env bash
# =============================================================================
# CLARE release-lib.sh — Shared helpers for release automation scripts
# =============================================================================

set -euo pipefail

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
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  RESET=''
fi

rl_info() { echo -e "${CYAN}INFO ${RESET}$*"; }
rl_ok() { echo -e "${GREEN}OK   ${RESET}$*"; }
rl_warn() { echo -e "${YELLOW}WARN ${RESET}$*"; }
rl_error() { echo -e "${RED}ERR  ${RESET}$*" >&2; }

rl_die() {
  local exit_code="$1"
  shift
  rl_error "$*"
  exit "$exit_code"
}

rl_require_command() {
  local command_name="$1"
  local hint="${2:-}"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      rl_die 3 "Required command not found: $command_name ($hint)"
    fi
    rl_die 3 "Required command not found: $command_name"
  fi
}

rl_validate_semver() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?(\+[0-9A-Za-z.]+)?$ ]]
}

rl_read_version_file() {
  local version_file="$1"
  [[ -f "$version_file" ]] || rl_die 3 "VERSION file not found: $version_file"
  local version
  version="$(tr -d '[:space:]' <"$version_file")"
  [[ -n "$version" ]] || rl_die 3 "VERSION file is empty: $version_file"
  rl_validate_semver "$version" || rl_die 3 "Invalid semantic version in VERSION: $version"
  echo "$version"
}

rl_require_main_branch() {
  local expected_branch="${1:-main}"
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ "$current_branch" != "HEAD" ]] || rl_die 3 "Releases cannot run from detached HEAD; checkout '$expected_branch' first"
  [[ "$current_branch" == "$expected_branch" ]] || rl_die 3 "Releases must be run from '$expected_branch' (current: '$current_branch')"
}

rl_require_clean_tree() {
  local status
  status="$(git status --porcelain)"
  [[ -z "$status" ]] || rl_die 3 "Git tree is not clean. Commit, stash, or discard changes before releasing."
}

rl_tag_exists() {
  local tag_name="$1"
  if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
    return 0
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

rl_run() {
  local dry_run="$1"
  shift
  local cmd=("$@")
  if [[ "$dry_run" == "true" ]]; then
    printf 'DRY_RUN: '
    printf '%q ' "${cmd[@]}"
    printf '\n'
    return 0
  fi
  "${cmd[@]}"
}
