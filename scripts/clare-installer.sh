#!/usr/bin/env bash
# =============================================================================
# clare-installer.sh — Unified CLARE installer (source-tree + self-extracting)
# =============================================================================
# Source-tree mode:
#   ./scripts/clare-installer.sh --target /path/to/project
#
# Self-extracting mode:
#   ./clare-installer-vX.Y.Z.sh --target /path/to/project
#
# Extra modes:
#   --extract <path>            Extract full payload only (self-extracting mode)
#   --install-examples <path>   Extract templates/examples only
# =============================================================================

set -euo pipefail

EXIT_USAGE=2
EXIT_PREFLIGHT=3
EXIT_RUNTIME=4
EXIT_EXTRACT=5
EXIT_ABORT=6

SCRIPT_SELF="${BASH_SOURCE:-$0}"
SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)/$(basename "$SCRIPT_SELF")"

TARGET_DIR=""
DRY_RUN=false
FORCE=false
YES=false
AUTO_UPDATE=false
EXTRACT_PATH=""
INSTALL_EXAMPLES_PATH=""
INSTALL_SKILLS=""
RUN_SETUP=true
SETUP_ONLY=false
UPDATE=false
WORK_DIR=""
HAS_TTY=false
TARGET_WAS_DIRTY=false

readonly CLARE_RELATED_PATHS=(
  "clare"
  ".github/copilot-instructions.md"
  ".github/instructions"
  ".github/hooks"
  ".github/prompts"
  ".cursor/rules"
  ".claude/commands"
  ".vscode/prompts"
  ".codex/skills"
  ".codex/hooks.json"
  ".claude/settings.json"
  "CLAUDE.md"
  "AGENTS.md"
  ".cursorrules"
  ".gitignore"
)

if [[ -t 0 && -t 1 ]]; then
  HAS_TTY=true
fi

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
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

error() { echo -e "${RED}❌ $*${NC}" >&2; }
info() { echo -e "${BLUE}ℹ  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }

escape_sed_regex() {
  printf '%s\n' "$1" | sed 's/[][\\.^$*+?{}|()/]/\\&/g'
}

header() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════${NC}"
  echo ""
}

detect_installer_version() {
  local script_name
  script_name="$(basename "$SCRIPT_PATH")"

  if [[ "$script_name" =~ ^clare-installer-v([0-9]+\.[0-9]+\.[0-9]+)\.sh$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  local version_file
  version_file="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)/VERSION"
  if [[ -f "$version_file" ]]; then
    head -n 1 "$version_file"
    return 0
  fi

  echo "0.0.0"
}

usage() {
  cat <<'USAGE'
Usage:
  clare-installer.sh [--target <path>] [--dry-run] [--force] [--yes] [--no-setup]
  clare-installer.sh --update [--target <path>] [--dry-run] [--yes|--auto-update] [--no-setup]
  clare-installer.sh --install-examples <path> [--force]
  clare-installer.sh --extract <path> [--force]
  clare-installer.sh [--dry-run] /path/to/project

Options:
  --target <path>   Target repository path
  --update          Required when updating an existing CLARE installation.
                    Prompts per changed file: [U]pdate, (d)iff, (s)kip, (a)bort
  --dry-run         Show what would happen without modifying target files
  --force           Allow overwrite for --extract/--install-examples collisions
  --yes             Auto-confirm prompts (including --update file prompts)
  --auto-update     During --update, apply changed CLARE-managed files and
                    installed extension updates without prompting
  --no-setup        Skip running setup wizard after install/update
  --setup-only      Run setup flow only (internal use)
  --install-examples <path>
                    Extract CLARE examples to <path> and exit
  --install-skill <list|all>
                    Non-interactively install skills during setup. Pass a
                    quoted, space-separated list of numeric indices (as shown
                    in the skill prompt) or "all".
  --extract <path>  Extract full embedded payload only, do not install/update
  
Setup flow (runs by default after install/update unless --no-setup):
  1. Project info
  2. Autonomy boundaries
  3. Script permissions
  4. Skill installation (optional)
  5. Extensions setup (optional)

Standalone setup:
  ./scripts/clare-installer.sh --target <path> --setup-only
  --help            Show this help
USAGE
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

ensure_git_repo() {
  local dir="$1"
  if ! command -v git >/dev/null 2>&1; then
    error "git is required but not found in PATH"
    return 1
  fi
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    error "Target directory is not a git repository: $dir"
    error "Initialize git first (e.g., git init) and run installer again"
    return 1
  fi
}

check_repo_dirty_state() {
  local dir="$1"

  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    TARGET_WAS_DIRTY=true
  else
    TARGET_WAS_DIRTY=false
  fi
}

warn_if_repo_dirty_before_install() {
  local dir="$1"

  check_repo_dirty_state "$dir"

  if [[ "$TARGET_WAS_DIRTY" == "true" ]]; then
    warn "Target repository has existing changes."
    warn "Recommended: commit or stash current changes before install/update so CLARE changes can be isolated in a single commit."

    if [[ "$YES" == "true" ]]; then
      warn "Continuing because --yes was provided."
      return 0
    fi

    if ! $HAS_TTY; then
      error "Refusing to continue with dirty working tree in non-interactive mode. Re-run with --yes to proceed."
      return 1
    fi

    if ! ask_yn "Continue install/update with dirty working tree?" "n"; then
      error "Aborted. Commit or stash changes, then re-run installer."
      return 1
    fi
  fi

  return 0
}

show_clare_related_diffstat() {
  local dir="$1"
  local has_changes=false
  local diff_output untracked_output

  diff_output="$(git -C "$dir" diff --stat -- "${CLARE_RELATED_PATHS[@]}" 2>/dev/null || true)"
  if [[ -n "$diff_output" ]]; then
    echo "$diff_output"
    has_changes=true
  fi

  untracked_output="$(git -C "$dir" ls-files --others --exclude-standard -- "${CLARE_RELATED_PATHS[@]}" 2>/dev/null || true)"
  if [[ -n "$untracked_output" ]]; then
    while IFS= read -r rel_path; do
      [[ -z "$rel_path" ]] && continue
      printf " %s | 0\n" "$rel_path"
    done <<<"$untracked_output"
    has_changes=true
  fi

  if [[ "$has_changes" == "false" ]]; then
    info "No CLARE-related working-tree changes detected."
    return 1
  fi

  if [[ "$TARGET_WAS_DIRTY" == "true" ]]; then
    warn "Diffstat may include CLARE-related changes that existed before this run."
  fi

  return 0
}

maybe_commit_clare_changes() {
  local dir="$1"

  header "CLARE Setup — Post-Install Review"
  info "CLARE-related diffstat (working tree):"
  echo ""

  if ! show_clare_related_diffstat "$dir"; then
    return 0
  fi

  echo ""
  if ask_yn "Commit these CLARE-related changes now with message 'CLARE framework updated'?" "n"; then
    git -C "$dir" add -- "${CLARE_RELATED_PATHS[@]}"
    if git -C "$dir" diff --cached --quiet -- "${CLARE_RELATED_PATHS[@]}"; then
      info "No staged CLARE-related changes to commit."
      return 0
    fi
    if git -C "$dir" commit -m "CLARE framework updated"; then
      success "Created commit: CLARE framework updated"
    else
      error "Failed to create commit. Review git status and commit manually."
      return 1
    fi
  else
    info "Skipped auto-commit."
  fi
}

has_clare_install() {
  local dir="$1"
  [[ -f "$dir/clare/autonomy.yml" || -f "$dir/clare/verify-ci.sh" || -f "$dir/clare/principles.md" ]]
}

has_legacy_clear_install() {
  local dir="$1"
  [[ -f "$dir/clear/autonomy.yml" || -f "$dir/clear/verify-ci.sh" || -f "$dir/clear/principles.md" ]]
}

rename_legacy_file() {
  local old_path="$1"
  local new_path="$2"
  local old_rel="${old_path#"$TARGET_DIR"/}"
  local new_rel="${new_path#"$TARGET_DIR"/}"

  [[ -e "$old_path" ]] || return 0

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -e "$new_path" ]]; then
      echo "  - $old_rel (legacy renamed file already replaced by $new_rel)"
    else
      echo "  > $old_rel -> $new_rel"
    fi
    return 0
  fi

  if [[ -e "$new_path" ]]; then
    rm -f "$old_path"
    info "Removed legacy renamed file: $old_rel"
  else
    mkdir -p "$(dirname "$new_path")"
    mv "$old_path" "$new_path"
    info "Renamed legacy file: $old_rel -> $new_rel"
  fi
}

cleanup_empty_dirs_upward() {
  local dir="$1"
  local stop="$2"

  while [[ "$dir" != "$stop" && "$dir" == "$stop"* ]]; do
    rmdir "$dir" 2>/dev/null || break
    dir="$(dirname "$dir")"
  done
}

migrate_legacy_clear_install() {
  local target="$1"
  local old_dir="$target/clear"
  local new_dir="$target/clare"

  has_legacy_clear_install "$target" || return 0

  warn "Detected legacy CLARE installation in clear/. The target repository will be renamed to clare/."

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -e "$new_dir" ]]; then
      echo "  - clear/ (legacy directory; clare/ already exists, would remove renamed CLARE-managed files)"
    else
      echo "  > clear/ -> clare/"
    fi
  elif [[ -e "$new_dir" ]]; then
    local legacy_items=(
      autonomy.yml
      verify-ci.sh
      verify-local.sh
      principles.md
      extensions.yml
      templates
      examples
      docs
    )
    for item in "${legacy_items[@]}"; do
      if [[ -e "$old_dir/$item" ]]; then
        # ${old_dir:?} guards against an empty $old_dir ever expanding the path
        # to "/$item" and removing from the filesystem root.
        rm -rf "${old_dir:?}/$item"
        info "Removed legacy renamed path: clear/$item"
      fi
    done
    rmdir "$old_dir" 2>/dev/null || warn "Legacy clear/ still contains non-CLARE files; leaving it in place."
  else
    mv "$old_dir" "$new_dir"
    success "Renamed clear/ to clare/"
  fi

  local rule
  for rule in workflow constrained limited assertive reality-aligned ephemeral release; do
    rename_legacy_file "$target/.cursor/rules/clear-$rule.mdc" "$target/.cursor/rules/clare-$rule.mdc"
  done

  if [[ "$DRY_RUN" != "true" ]]; then
    cleanup_empty_dirs_upward "$target/.cursor/rules" "$target"
  fi
}

has_embedded_payload() {
  awk '/^__CLARE_PAYLOAD_BELOW__$/ { found=1; exit } END { exit(found ? 0 : 1) }' "$SCRIPT_PATH"
}

extract_payload() {
  local destination="$1"
  local marker_line

  marker_line="$(awk '/^__CLARE_PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$SCRIPT_PATH")"
  [[ -n "$marker_line" ]] || {
    error "Installer payload marker not found"
    return 1
  }

  mkdir -p "$destination"
  tail -n "+$marker_line" "$SCRIPT_PATH" | tar -xzf - -C "$destination"
}

copy_file_update() {
  local src="$1"
  local dst="$2"
  prompt_update_file "$src" "$dst" || exit "$EXIT_ABORT"
}

copy_file_if_missing() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "$dst" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
}

ensure_gitignore_entry() {
  local gitignore_file="$1"
  local entry="$2"
  local label="$3"

  mkdir -p "$(dirname "$gitignore_file")"
  touch "$gitignore_file"

  if grep -Fxq "$entry" "$gitignore_file"; then
    return 0
  fi

  {
    if [[ -s "$gitignore_file" ]]; then
      printf '\n'
    fi
    printf '# %s\n' "$label"
    printf '%s\n' "$entry"
  } >>"$gitignore_file"
}

copy_dir_update() {
  local src_dir="$1"
  local dst_dir="$2"
  local skip_prefix="${3:-}"
  local exclude_files="${4:-}"

  [[ -d "$src_dir" ]] || return 0

  while IFS= read -r -d '' src_file; do
    local rel
    rel="${src_file#"$src_dir"/}"
    if [[ -n "$skip_prefix" && "$rel" == "$skip_prefix"* ]]; then
      continue
    fi
    if [[ -n "$exclude_files" ]]; then
      local excluded
      for excluded in $exclude_files; do
        [[ "$rel" == "$excluded" ]] && continue 2
      done
    fi

    local dst_file
    dst_file="$dst_dir/$rel"
    prompt_update_file "$src_file" "$dst_file" || exit "$EXIT_ABORT"
  done < <(find "$src_dir" -type f -print0 | sort -z)
}

ensure_clare2_autonomy_boundaries() {
  local target_dir="$1"
  local autonomy_file="$target_dir/clare/autonomy.yml"
  local autonomy_rel="${autonomy_file#"$target_dir"/}"
  local temporary

  [[ -f "$autonomy_file" ]] || return 0

  if git -C "$target_dir" ls-files --error-unmatch "$autonomy_rel" \
    >/dev/null 2>&1 \
    && [[ -n "$(git -C "$target_dir" status --porcelain -- "$autonomy_rel")" ]]; then
    warn "Skipped CLARE2 autonomy boundaries: $autonomy_rel has local changes"
    return 0
  fi

  if ! temporary="$(mktemp)"; then
    error "Failed to create temporary file while syncing CLARE2 autonomy boundaries"
    return 1
  fi

  awk '
    function unquote(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      return value
    }
    function emit_boundaries() {
      if (emitted) {
        return
      }
      if (!seen_clare) {
        print "  - path: \"clare\""
        print "    level: humans-only"
        print "    reason: \"CLARE-owned infrastructure; all changes require human review\""
        print ""
      }
      if (!seen_clare2) {
        print "  - path: \"clare2\""
        print "    level: supervised"
        print "    reason: \"Project-owned CLARE2 service; changes require human review\""
        print ""
      }
      if (!seen_hooks) {
        print "  - path: \"clare2/templates/hooks\""
        print "    level: humans-only"
        print "    reason: \"Authoritative provider hook definitions; CLARE consumes but does not overwrite these assets\""
        print ""
      }
      if (!seen_installer) {
        print "  - path: \"clare2/scripts/clare2-install-hooks.sh\""
        print "    level: humans-only"
        print "    reason: \"Authoritative hook installer; changes affect every configured agent provider\""
        print ""
      }
      emitted = 1
    }
    {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/) {
        path = $0
        sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", path)
        path = unquote(path)
        if (path == "clare") seen_clare = 1
        if (path == "clare2") seen_clare2 = 1
        if (path == "clare2/templates/hooks") seen_hooks = 1
        if (path == "clare2/scripts/clare2-install-hooks.sh") seen_installer = 1
        if (path == "*") emit_boundaries()
      }
      print
    }
    END {
      if (!emitted) emit_boundaries()
    }
  ' "$autonomy_file" >"$temporary"

  if ! cmp -s "$autonomy_file" "$temporary"; then
    mv "$temporary" "$autonomy_file"
    info "Added authoritative CLARE2 boundaries to clare/autonomy.yml"
  else
    rm -f "$temporary"
  fi
}

# install_clare2_corpus_capture <source_root> <target_dir>
#   clare/verify-ci.sh emits CLARE2 corpus signals (_clare2_emit_ci_result,
#   _clare2_autonomy_tier, etc.) and is one of the key corpus-generation
#   layers. Its capture-event/hook-install scripts and the provider hook
#   wiring they create are dependencies of that role, so they are kept in
#   sync alongside verify-ci.sh rather than gated behind skill selection.
install_clare2_corpus_capture() {
  local source_root="$1"
  local target_dir="$2"
  local capture_script="$source_root/install/clare/templates/scripts/clare2-capture-event.sh"
  local hook_installer="$source_root/install/clare/templates/scripts/clare2-install-hooks.sh"
  local authoritative_installer="$target_dir/clare2/scripts/clare2-install-hooks.sh"

  [[ -f "$capture_script" && -f "$hook_installer" ]] || return 0

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -f "$authoritative_installer" ]]; then
      info "Dry run: would install clare/scripts/clare2-capture-event.sh and run authoritative clare2 hook installer"
    else
      info "Dry run: would install clare/scripts/clare2-{capture-event,install-hooks}.sh and run hook installer"
    fi
    info "Dry run: would set CLARE2_CORPUS_ROOT in ~/.bashrc and link ${target_dir}/corpus → ~/.config/clare/corpus"
    return 0
  fi

  mkdir -p "$target_dir/clare/scripts"
  prompt_update_file \
    "$capture_script" \
    "$target_dir/clare/scripts/clare2-capture-event.sh" || return 1
  chmod +x "$target_dir/clare/scripts/clare2-capture-event.sh"

  if [[ -f "$authoritative_installer" ]]; then
    hook_installer="$authoritative_installer"
    info "Using project-owned clare2 hook assets"
  else
    prompt_update_file \
      "$hook_installer" \
      "$target_dir/clare/scripts/clare2-install-hooks.sh" || return 1
    hook_installer="$target_dir/clare/scripts/clare2-install-hooks.sh"
    chmod +x "$hook_installer"
  fi

  if [[ "$hook_installer" == "$authoritative_installer" ]]; then
    if ! bash "$hook_installer" "$target_dir" >/dev/null; then
      warn "Authoritative CLARE2 hook installer failed; provider hooks need manual setup"
      return 0
    fi
  else
    if ! (cd "$target_dir" && ./clare/scripts/clare2-install-hooks.sh >/dev/null); then
      warn "CLARE2 corpus capture scripts installed, but provider hooks need manual setup"
      return 0
    fi
  fi

  if [[ -f "$target_dir/.github/hooks/clare2-corpus.json" ]]; then
    success "Installed CLARE2 corpus capture scripts and provider hooks"
  else
    warn "CLARE2 corpus capture scripts installed, but provider hooks need manual setup"
  fi

  _install_corpus_root "$target_dir"
}

# _install_corpus_root <target_dir>
#   Ensures ~/.config/clare/corpus exists, writes CLARE2_CORPUS_ROOT to the
#   user's shell profile (if not already present), and symlinks target_dir/corpus
#   → ~/.config/clare/corpus so the pipeline container's bind-mount continues
#   to resolve to the shared user corpus.
_install_corpus_root() {
  local target_dir="$1"
  local corpus_root="${HOME}/.config/clare/corpus"
  local corpus_line="export CLARE2_CORPUS_ROOT=\"\${HOME}/.config/clare/corpus\""

  mkdir -p "$corpus_root"

  # Write CLARE2_CORPUS_ROOT to shell profiles (idempotent)
  local added_to=()
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -qF 'CLARE2_CORPUS_ROOT' "$rc" && continue
    printf '\n# CLARE2 corpus root (set by clare-installer)\n%s\n' "$corpus_line" >>"$rc"
    added_to+=("$rc")
  done
  if [[ ${#added_to[@]} -gt 0 ]]; then
    info "Added CLARE2_CORPUS_ROOT to: ${added_to[*]}"
    info "Run: source ${added_to[0]}  (or open a new terminal)"
  fi

  # Symlink target_dir/corpus → shared user corpus so the pipeline container
  # reads from the same location without needing a docker-compose change.
  local target_corpus="$target_dir/corpus"
  if [[ -L "$target_corpus" ]]; then
    : # already a symlink — leave it
  elif [[ -d "$target_corpus" ]]; then
    # Real directory: migrate contents then replace with symlink
    if [[ "$(find "$target_corpus" -mindepth 1 -not -name '.gitignore' -not -name '.gitkeep' 2>/dev/null | head -1)" == "" ]]; then
      rm -rf "$target_corpus"
      ln -s "$corpus_root" "$target_corpus"
      info "Linked $target_corpus → $corpus_root"
    else
      warn "$target_corpus is a non-empty directory; skipping symlink. Move its contents to $corpus_root manually, then: rm -rf \"$target_corpus\" && ln -s \"$corpus_root\" \"$target_corpus\""
    fi
  fi
}

# merge_json_config <project> <template> <merge_type> <out>
#   Merges a CLARE-managed .vscode/*.json template into a project's existing
#   file, writing the result to <out>. <merge_type> selects the jq filter:
#     settings   - recursive object merge; template values win on key
#                   conflicts, all other project keys are preserved
#     extensions - union of .recommendations[], project order first, new
#                   template entries appended
#     tasks      - union of .tasks[] by .label; template wins on matching
#                   labels, project-only labels preserved, new template
#                   labels appended
merge_json_config() {
  local project="$1"
  local template="$2"
  local merge_type="$3"
  local out="$4"

  case "$merge_type" in
    settings)
      jq -s '.[0] * .[1]' "$project" "$template" >"$out"
      ;;
    extensions)
      jq -s '
        .[0].recommendations as $p | .[1].recommendations as $t |
        {recommendations: ($p + ($t - $p))}
      ' "$project" "$template" >"$out"
      ;;
    tasks)
      jq -s '
        .[0] as $p | .[1] as $t |
        ($p.tasks | map(.label)) as $plabels |
        ($t.tasks | map(.label)) as $tlabels |
        ($plabels + ($tlabels - $plabels)) as $order |
        ($t.tasks | INDEX(.label)) as $tmap |
        ($p.tasks | INDEX(.label)) as $pmap |
        {
          version: $t.version,
          tasks: [ $order[] | ($tmap[.] // $pmap[.]) ]
        }
      ' "$project" "$template" >"$out"
      ;;
    *)
      error "merge_json_config: unknown merge_type: $merge_type"
      return 1
      ;;
  esac
}

# describe_json_config_changes <project> <template> <merge_type>
#   Prints a short human-readable summary of what the template would
#   add/update relative to the project's current file. Empty output means
#   no changes.
describe_json_config_changes() {
  local project="$1"
  local template="$2"
  local merge_type="$3"

  case "$merge_type" in
    settings)
      jq -n --slurpfile p "$project" --slurpfile t "$template" -r '
        ($p[0]) as $proj | ($t[0]) as $tmpl |
        [$tmpl | keys[] | select(($proj[.] // null) != $tmpl[.])] |
        if length == 0 then empty
        else "added/updated " + (length | tostring) + " key(s): " + join(", ")
        end
      '
      ;;
    extensions)
      jq -n --slurpfile p "$project" --slurpfile t "$template" -r '
        ($t[0].recommendations - $p[0].recommendations) as $new |
        if ($new | length) == 0 then empty
        else "added " + ($new | length | tostring) + " recommendation(s): " + ($new | join(", "))
        end
      '
      ;;
    tasks)
      jq -n --slurpfile p "$project" --slurpfile t "$template" -r '
        ($p[0].tasks | INDEX(.label)) as $pmap |
        [$t[0].tasks[] | select($pmap[.label] != .) | .label] as $changed |
        if ($changed | length) == 0 then empty
        else "added/updated " + ($changed | length | tostring) + " task(s): " + ($changed | join(", "))
        end
      '
      ;;
  esac
}

# merge_or_copy_vscode_json <src> <dst> <merge_type>
#   Project-customizable .vscode/*.json files are merged rather than
#   overwritten: CLARE template keys/entries are added or updated, and any
#   project-added content is preserved. Before merging, the target file's
#   git status is checked - a dirty or untracked file is left untouched so
#   that a CLARE merge is always cleanly reversible via `git diff`/
#   `git checkout`.
merge_or_copy_vscode_json() {
  local src="$1"
  local dst="$2"
  local merge_type="$3"
  local rel="${dst#"$TARGET_DIR"/}"

  # New file - plain copy, nothing to merge.
  if [[ ! -e "$dst" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  + $rel (new)"
      return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    return 0
  fi

  # Identical - nothing to do.
  if cmp -s "$src" "$dst"; then
    return 0
  fi

  local status
  status="$(git -C "$TARGET_DIR" status --porcelain -- "$rel" 2>/dev/null || true)"
  if [[ -n "$status" ]]; then
    local reason="uncommitted changes"
    [[ "$status" == "??"* ]] && reason="untracked"
    warn "skipped: $rel ($reason) — commit or stash $rel, then re-run --update to merge CLARE recommendations"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local summary
    summary="$(describe_json_config_changes "$dst" "$src" "$merge_type")"
    if [[ -n "$summary" ]]; then
      echo "  ~ $rel ($summary)"
    fi
    return 0
  fi

  local summary
  summary="$(describe_json_config_changes "$dst" "$src" "$merge_type")"
  [[ -n "$summary" ]] || return 0

  local temporary
  temporary=$(mktemp)
  merge_json_config "$dst" "$src" "$merge_type" "$temporary"
  jq -e . "$temporary" >/dev/null
  mv "$temporary" "$dst"
  success "merged: $rel ($summary)"
}

# prompt_update_file src dst
#   Central file-write function for managed files during update.
#   - New file (dst missing): create without prompting
#   - Identical file: skip silently
#   - Dry-run: print what would happen, return
#   - Fresh install: overwrite without prompting
#   - --yes, --auto-update, or no TTY: auto-confirm
#   - Interactive: prompt [U]pdate / (d)iff / (s)kip / (a)bort
#   Returns 0 on success/skip, 1 on user abort.
prompt_update_file() {
  local src="$1"
  local dst="$2"
  local rel="${dst#"$TARGET_DIR"/}"

  # New file — just create it
  if [[ ! -e "$dst" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  + $rel (new)"
      return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    return 0
  fi

  # Identical — skip silently
  if cmp -s "$src" "$dst"; then
    return 0
  fi

  # Dry-run — report and return
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  ~ $rel (changed)"
    return 0
  fi

  # Fresh install — overwrite without prompting
  if [[ "$is_fresh_install" == "true" ]]; then
    cp "$src" "$dst"
    return 0
  fi

  # --yes, --auto-update, or no TTY — auto-confirm
  if [[ "$YES" == "true" || "$AUTO_UPDATE" == "true" ]] || ! $HAS_TTY; then
    cp "$src" "$dst"
    info "  updated: $rel"
    return 0
  fi

  # Interactive prompt loop
  while true; do
    printf "  %s changed — [U]pdate / (d)iff / (s)kip / (a)bort: " "$rel" >/dev/tty
    local choice
    read -r choice </dev/tty
    choice="${choice:-u}"
    case "${choice,,}" in
      u | update)
        cp "$src" "$dst"
        success "  updated: $rel"
        return 0
        ;;
      d | diff)
        if command -v diff >/dev/null 2>&1; then
          diff -u "$dst" "$src" --label "installed/$rel" --label "new/$rel" || true
        else
          warn "  diff not available; showing file sizes instead"
          echo "    installed: $(wc -c <"$dst") bytes"
          echo "    new:       $(wc -c <"$src") bytes"
        fi
        ;;
      s | skip)
        info "  skipped: $rel"
        return 0
        ;;
      a | abort)
        error "Update aborted by user."
        return 1
        ;;
      *)
        echo "  Invalid choice. Enter u, d, s, or a." >/dev/tty
        ;;
    esac
  done
}

ask() {
  local question="$1"
  local default="${2:-}"
  local answer

  if [[ "$YES" == "true" ]]; then
    echo "$default"
    return 0
  fi

  if ! $HAS_TTY; then
    echo "$default"
    return 0
  fi

  if [[ -n "$default" ]]; then
    printf "?  %s [%s]: " "$question" "$default" >&2
  else
    printf "?  %s: " "$question" >&2
  fi
  read -r answer
  echo "${answer:-$default}"
}

ask_yn() {
  local question="$1"
  local default="${2:-y}"
  local answer

  if [[ "$YES" == "true" ]]; then
    [[ "$default" =~ ^[Yy]$ ]]
    return
  fi

  if ! $HAS_TTY; then
    [[ "$default" =~ ^[Yy]$ ]]
    return
  fi

  if [[ "$default" == "y" ]]; then
    printf "?  %s [Y/n]: " "$question" >&2
  else
    printf "?  %s [y/N]: " "$question" >&2
  fi

  read -r answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

get_skill_meta() {
  local file="$1"
  local field="$2"
  local first_line

  first_line=$(head -1 "$file")
  if [[ "$first_line" == "---" ]]; then
    awk -v f="${field}" '
      NR==1{next}
      /^---$/{exit}
      $0 ~ ("^[[:space:]]*" f "[[:space:]]*:"){
        val=$0
        sub("^[[:space:]]*" f "[[:space:]]*:[[:space:]]*", "", val)
        sub(/^[[:space:]"\x27]+/,"",val)
        sub(/[[:space:]"\x27]+$/,"",val)
        print val
        exit
      }
    ' "$file"
  elif [[ "$field" == "name" ]]; then
    basename "$file" .md
  else
    awk '/^# CLARE Skill:/{sub(/^# CLARE Skill: /,""); print; exit}' "$file"
  fi
}

sync_autonomy_project_name() {
  local autonomy_file="$1"
  local selected_project_name="$2"
  local escaped_project_name tmp_file

  [[ -f "$autonomy_file" ]] || return 0

  escaped_project_name="${selected_project_name//\"/\\\"}"
  if ! tmp_file="$(mktemp)"; then
    error "Failed to create temporary file while syncing autonomy project name"
    return 1
  fi

  awk -v project_name="$escaped_project_name" '
    BEGIN {
      replaced = 0
      inserted = 0
    }
    /^[[:space:]]*project:[[:space:]]*/ {
      if (replaced == 0) {
        print "project: \"" project_name "\""
        replaced = 1
      }
      next
    }
    /^[[:space:]]*modules:[[:space:]]*$/ {
      if (replaced == 0 && inserted == 0) {
        print "project: \"" project_name "\""
        print ""
        inserted = 1
      }
      print
      next
    }
    { print }
    END {
      if (replaced == 0 && inserted == 0) {
        print ""
        print "project: \"" project_name "\""
      }
    }
  ' "$autonomy_file" >"$tmp_file"

  if ! cmp -s "$autonomy_file" "$tmp_file"; then
    mv "$tmp_file" "$autonomy_file"
    info "Synced project name in clare/autonomy.yml: $selected_project_name"
  else
    rm -f "$tmp_file"
  fi
}

setup_set_extension_enabled_state() {
  local config_file="$1"
  local extension_name="$2"
  local state="$3"
  local escaped_ext
  escaped_ext="$(escape_sed_regex "$extension_name")"

  sed -i "/name:[[:space:]]*${escaped_ext}/,/enabled:/ { s/enabled:[[:space:]]*false/enabled: ${state}/; s/enabled:[[:space:]]*true/enabled: ${state}/; }" "$config_file"
}

setup_get_extension_enabled_state() {
  local config_file="$1"
  local extension_name="$2"

  awk -v ext_name="$extension_name" '
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }

    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      name = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
      sub(/[[:space:]]*#.*/, "", name)
      gsub(/"/, "", name)
      name = trim(name)
      in_block = (name == ext_name)
      next
    }

    in_block && /^[[:space:]]*enabled:[[:space:]]*/ {
      enabled = $0
      sub(/^[[:space:]]*enabled:[[:space:]]*/, "", enabled)
      sub(/[[:space:]]*#.*/, "", enabled)
      enabled = trim(enabled)
      if (enabled == "true" || enabled == "false") {
        print enabled
        exit
      }
    }
  ' "$config_file"
}

setup_maybe_migrate_legacy_extensions() {
  local config_file="$1"
  local latest_file="$2"
  local setup_target="$3"
  local migrate="false"
  local lizard_enabled
  local file_size_enabled
  local backup_file

  [[ -f "$config_file" && -f "$latest_file" ]] || return 0

  if ! grep -Eq '^[[:space:]]*-[[:space:]]*name:[[:space:]]*lizard([[:space:]]|$)' "$config_file"; then
    return 0
  fi

  if grep -Eq '^[[:space:]]*-[[:space:]]*name:[[:space:]]*(eslint-complexity|golangci-lint-complexity|complexipy-complexity)([[:space:]]|$)' "$config_file"; then
    warn "Legacy extension 'lizard' detected in clare/extensions.yml; migrate manually to language-specific extensions"
    return 0
  fi

  warn "Detected legacy lizard extension configuration in clare/extensions.yml"
  if [[ "$YES" == "true" ]]; then
    migrate="true"
  elif [[ "$HAS_TTY" == "true" ]] && ask_yn "Migrate legacy lizard config to current extension defaults now?" "y"; then
    migrate="true"
  fi

  if [[ "$migrate" != "true" ]]; then
    info "Keeping existing legacy extensions config"
    return 0
  fi

  lizard_enabled="$(setup_get_extension_enabled_state "$config_file" "lizard")"
  file_size_enabled="$(setup_get_extension_enabled_state "$config_file" "file-size")"

  backup_file="$config_file.bak.pre-lizard-migration"
  cp "$config_file" "$backup_file"
  cp "$latest_file" "$config_file"

  if [[ "$lizard_enabled" == "true" ]]; then
    setup_set_extension_enabled_state "$config_file" "eslint-complexity" "true"
  fi

  if [[ "$file_size_enabled" == "true" ]]; then
    setup_set_extension_enabled_state "$config_file" "file-size" "true"
  fi

  success "Migrated legacy extensions config to current defaults"
  info "Backup created: ${backup_file#"$setup_target"/}"
}

list_extension_names() {
  local config_file="$1"

  awk '
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }

    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      name = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
      sub(/[[:space:]]*#.*/, "", name)
      gsub(/"/, "", name)
      name = trim(name)
      if (name != "") {
        print name
      }
    }
  ' "$config_file"
}

extract_extension_block() {
  # Block boundaries are delimited solely by `- name:` lines: a block runs from
  # its own name line up to (but not including) the next one. Consequences of
  # this assumption, both acceptable for extensions.yml's current layout:
  #   - Header comments that precede the *next* extension are attributed to the
  #     *current* block, so editing a later extension's doc comment can surface a
  #     spurious "this block changed" prompt.
  #   - If a matched extension were the last list item followed by other
  #     top-level YAML keys, those keys would be swept into the block. Today the
  #     last extension (file-size) is the final content in the file, so this
  #     cannot bite — but a future top-level key after the list would need a
  #     dedent-aware boundary here and in replace_extension_block.
  local config_file="$1"
  local extension_name="$2"
  local output_file="$3"

  awk -v ext_name="$extension_name" '
    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }

    function parsed_name(line, name) {
      name = line
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
      sub(/[[:space:]]*#.*/, "", name)
      gsub(/"/, "", name)
      return trim(name)
    }

    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      if (in_block) {
        exit
      }
      in_block = (parsed_name($0) == ext_name)
    }

    in_block {
      print
      found = 1
    }

    END {
      exit(found ? 0 : 1)
    }
  ' "$config_file" >"$output_file"
}

set_extension_block_enabled_state() {
  local block_file="$1"
  local state="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v state="$state" '
    done == 0 && /^[[:space:]]*enabled:[[:space:]]*/ {
      sub(/enabled:[[:space:]]*(true|false)/, "enabled: " state)
      done = 1
    }

    { print }
  ' "$block_file" >"$tmp_file"

  mv "$tmp_file" "$block_file"
}

replace_extension_block() {
  local config_file="$1"
  local extension_name="$2"
  local replacement_file="$3"
  local tmp_file
  tmp_file="$(mktemp)"

  if awk -v ext_name="$extension_name" -v replacement_file="$replacement_file" '
    BEGIN {
      while ((getline line < replacement_file) > 0) {
        replacement = replacement line ORS
      }
      close(replacement_file)
    }

    function trim(s) {
      gsub(/^[[:space:]]+/, "", s)
      gsub(/[[:space:]]+$/, "", s)
      return s
    }

    function parsed_name(line, name) {
      name = line
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
      sub(/[[:space:]]*#.*/, "", name)
      gsub(/"/, "", name)
      return trim(name)
    }

    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      if (in_block) {
        in_block = 0
      }

      if (parsed_name($0) == ext_name) {
        printf "%s", replacement
        in_block = 1
        replaced = 1
        next
      }
    }

    in_block {
      next
    }

    { print }

    END {
      exit(replaced ? 0 : 1)
    }
  ' "$config_file" >"$tmp_file"; then
    mv "$tmp_file" "$config_file"
  else
    # The named block was not found; tmp_file holds an unverified copy of the
    # config. Discard it rather than overwriting the real file with a no-op.
    rm -f "$tmp_file"
    return 1
  fi
}

prompt_update_extension() {
  local config_file="$1"
  local latest_file="$2"
  local extension_name="$3"
  local setup_target="$4"
  local rel="${config_file#"$setup_target"/}"
  local installed_block latest_block latest_prepared current_enabled

  installed_block="$(mktemp)"
  latest_block="$(mktemp)"
  latest_prepared="$(mktemp)"

  if ! extract_extension_block "$config_file" "$extension_name" "$installed_block"; then
    rm -f "$installed_block" "$latest_block" "$latest_prepared"
    return 0
  fi

  if ! extract_extension_block "$latest_file" "$extension_name" "$latest_block"; then
    rm -f "$installed_block" "$latest_block" "$latest_prepared"
    return 0
  fi

  cp "$latest_block" "$latest_prepared"
  current_enabled="$(setup_get_extension_enabled_state "$config_file" "$extension_name")"
  if [[ "$current_enabled" == "true" || "$current_enabled" == "false" ]]; then
    set_extension_block_enabled_state "$latest_prepared" "$current_enabled"
  fi

  if cmp -s "$installed_block" "$latest_prepared"; then
    rm -f "$installed_block" "$latest_block" "$latest_prepared"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  ~ $rel ($extension_name extension changed)"
    rm -f "$installed_block" "$latest_block" "$latest_prepared"
    return 0
  fi

  if [[ "$YES" == "true" || "$AUTO_UPDATE" == "true" ]] || ! $HAS_TTY; then
    if replace_extension_block "$config_file" "$extension_name" "$latest_prepared"; then
      info "  updated: $rel ($extension_name extension)"
    else
      warn "  could not update $rel ($extension_name extension); left unchanged"
    fi
    rm -f "$installed_block" "$latest_block" "$latest_prepared"
    return 0
  fi

  while true; do
    printf "  %s extension '%s' changed — [U]pdate / (d)iff / (s)kip / (a)bort: " "$rel" "$extension_name" >/dev/tty
    local choice
    read -r choice </dev/tty
    choice="${choice:-u}"
    case "${choice,,}" in
      u | update)
        if replace_extension_block "$config_file" "$extension_name" "$latest_prepared"; then
          success "  updated: $rel ($extension_name extension)"
        else
          warn "  could not update $rel ($extension_name extension); left unchanged"
        fi
        rm -f "$installed_block" "$latest_block" "$latest_prepared"
        return 0
        ;;
      d | diff)
        if command -v diff >/dev/null 2>&1; then
          diff -u "$installed_block" "$latest_prepared" \
            --label "installed/$rel:$extension_name" \
            --label "new/$rel:$extension_name" || true
        else
          warn "  diff not available; showing extension block sizes instead"
          echo "    installed: $(wc -c <"$installed_block") bytes"
          echo "    new:       $(wc -c <"$latest_prepared") bytes"
        fi
        ;;
      s | skip)
        info "  skipped: $rel ($extension_name extension)"
        rm -f "$installed_block" "$latest_block" "$latest_prepared"
        return 0
        ;;
      a | abort)
        error "Update aborted by user."
        rm -f "$installed_block" "$latest_block" "$latest_prepared"
        return 1
        ;;
      *)
        echo "  Invalid choice. Enter u, d, s, or a." >/dev/tty
        ;;
    esac
  done
}

update_installed_extensions() {
  local config_file="$1"
  local latest_file="$2"
  local setup_target="$3"
  local extension_name

  [[ -f "$config_file" && -f "$latest_file" ]] || return 0

  while IFS= read -r extension_name; do
    [[ -n "$extension_name" ]] || continue
    prompt_update_extension "$config_file" "$latest_file" "$extension_name" "$setup_target" || exit "$EXIT_ABORT"
  done < <(list_extension_names "$config_file")
}

SETUP_INSTALLED_SKILLS=""

install_skill_item() {
  # install_skill_item <src_file> <name> <prompts_dir> <claude_commands_dir> <vscode_prompts_dir> <codex_skills_dir> <cursor_rules_dir> <setup_target>
  local src_file="$1"
  shift
  local name="$1"
  shift
  local prompts_dir="$1"
  shift
  local claude_commands_dir="$1"
  shift
  local vscode_prompts_dir="$1"
  shift
  local codex_skills_dir="$1"
  shift
  local cursor_rules_dir="$1"
  shift
  local setup_target="$1"
  shift

  # The clare-env-setup skill ships a helper script (clare-env-scan.sh). Its
  # instructions reference clare/scripts/clare-env-scan.sh relative to the
  # project root, so the script must actually be installed into the target —
  # otherwise the mirrored skill points at a path that does not exist. The
  # source root is the skill file's path minus the install/.../skills suffix.
  if [[ "$name" == "clare-env-setup" ]]; then
    local source_root="${src_file%/install/clare/templates/skills/*}"
    local env_scan_src="$source_root/install/clare/scripts/clare-env-scan.sh"
    if [[ -f "$env_scan_src" ]]; then
      mkdir -p "$setup_target/clare/scripts"
      cp "$env_scan_src" "$setup_target/clare/scripts/clare-env-scan.sh"
      chmod +x "$setup_target/clare/scripts/clare-env-scan.sh" 2>/dev/null || true
      success "Installed: clare/scripts/clare-env-scan.sh"
    else
      warn "clare-env-setup skill installed but $env_scan_src not found; env-scan script not copied"
    fi
  fi

  if [[ "$name" == "clare2-corpus-capture" ]]; then
    # Primary install path is the always-updated block (see
    # install_clare2_corpus_capture call near verify-ci.sh); this is a
    # refresh in case setup is run standalone against an older source tree.
    local source_root="${src_file%/install/clare/templates/skills/*}"
    install_clare2_corpus_capture "$source_root" "$setup_target" || return 1
  fi

  cp "$src_file" "$prompts_dir/${name}.prompt.md"
  cp "$src_file" "$claude_commands_dir/${name}.md"
  cp "$src_file" "$vscode_prompts_dir/${name}.prompt.md"
  if [[ -d "$codex_skills_dir" ]]; then
    mkdir -p "$codex_skills_dir/$name"
    cp "$src_file" "$codex_skills_dir/$name/SKILL.md"
  fi

  {
    echo "---"
    echo "description: CLARE skill mirror for $name"
    echo "alwaysApply: false"
    echo "---"
    echo ""
    cat "$src_file"
  } >"$cursor_rules_dir/skill-${name}.mdc"

  success "Installed: .github/prompts/${name}.prompt.md"
  success "Mirrored: .claude/commands/${name}.md"
  success "Mirrored: .cursor/rules/skill-${name}.mdc"
  success "Mirrored: .vscode/prompts/${name}.prompt.md"
  if [[ -d "$codex_skills_dir" ]]; then
    success "Mirrored: .codex/skills/${name}/SKILL.md"
  fi
  SETUP_INSTALLED_SKILLS="$SETUP_INSTALLED_SKILLS $name"
}

setup_install_skills_from_arrays() {
  local label="$1"
  shift
  local files_ref="$1"
  local names_ref="$2"
  local descs_ref="$3"
  local prompts_dir="$4"
  local claude_commands_dir="$5"
  local cursor_rules_dir="$6"
  local vscode_prompts_dir="$7"
  local codex_skills_dir="$8"
  local setup_target="$9"
  local -a _files=()
  local -a _names=()
  local -a _descs=()

  # Populate local copies of the referenced arrays without Bash namerefs.
  eval '_files=("${'"$files_ref"'[@]}")'
  eval '_names=("${'"$names_ref"'[@]}")'
  eval '_descs=("${'"$descs_ref"'[@]}")'

  [[ ${#_files[@]} -gt 0 ]] || return 0

  echo "$label (installed to .github/prompts/ and mirrored for Claude/Cursor/VS Code/Codex):"
  echo ""
  local _i
  for _i in "${!_files[@]}"; do
    printf "  %d. %s\n" "$((_i + 1))" "${_names[$_i]}"
    printf "     %s\n" "${_descs[$_i]}"
    echo ""
  done

  local selection
  selection="${INSTALL_SKILLS:-}"
  if [[ -z "$selection" ]]; then
    if [[ "$YES" != "true" && "$HAS_TTY" == "true" ]]; then
      printf "${CYAN}  Enter numbers to install (space-separated), 'all', or press ENTER to skip: ${NC}" >/dev/tty
      read -r selection </dev/tty
    elif [[ "$YES" != "true" ]]; then
      info "No TTY detected; skipping interactive skill selection"
    fi
  else
    info "Auto-selecting skills: $selection"
  fi
  echo ""

  if [[ -z "$selection" ]]; then
    info "Skipped"
    return 0
  fi

  local to_install=()
  if [[ "$selection" == "all" ]]; then
    for _i in "${!_files[@]}"; do
      to_install+=("$_i")
    done
  else
    local token
    for token in $selection; do
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        local idx=$((token - 1))
        if [[ $idx -ge 0 && $idx -lt ${#_files[@]} ]]; then
          to_install+=("$idx")
        else
          warn "No skill at position $token — skipped"
        fi
      fi
    done
  fi

  if [[ ${#to_install[@]} -eq 0 ]]; then
    return 0
  fi

  mkdir -p "$prompts_dir"
  mkdir -p "$claude_commands_dir"
  mkdir -p "$cursor_rules_dir"
  mkdir -p "$vscode_prompts_dir"
  if [[ -e "$setup_target/.codex" && ! -d "$setup_target/.codex" ]]; then
    warn ".codex exists but is not a directory; skipping Codex skill mirrors"
  else
    mkdir -p "$codex_skills_dir"
  fi

  local idx
  for idx in "${to_install[@]}"; do
    install_skill_item "${_files[$idx]}" "${_names[$idx]}" "$prompts_dir" "$claude_commands_dir" "$vscode_prompts_dir" "$codex_skills_dir" "$cursor_rules_dir" "$setup_target"
  done
}

setup_step_install_skills() {
  local skills_dir="$1"
  local prompts_dir="$2"
  local claude_commands_dir="$3"
  local cursor_rules_dir="$4"
  local vscode_prompts_dir="$5"
  local codex_skills_dir="$6"
  local setup_target="$7"

  header "CLARE Setup — Step 4: Install Skills [optional]"
  if [[ ! -d "$skills_dir" ]]; then
    info "No generic skills found in $skills_dir"
    return 0
  fi

  SKILL_FILES=()
  SKILL_NAMES=()
  SKILL_DESCS=()
  local skill_file
  for skill_file in "$skills_dir"/*.md; do
    [[ -f "$skill_file" ]] || continue
    SKILL_FILES+=("$skill_file")
    SKILL_NAMES+=("$(get_skill_meta "$skill_file" "name")")
    SKILL_DESCS+=("$(get_skill_meta "$skill_file" "description")")
  done

  setup_install_skills_from_arrays "Generic skills" SKILL_FILES SKILL_NAMES SKILL_DESCS \
    "$prompts_dir" "$claude_commands_dir" "$cursor_rules_dir" "$vscode_prompts_dir" "$codex_skills_dir" "$setup_target"
}

EXT_NAMES=()
EXT_DESCS=()
EXT_CMDS=()
EXT_HINTS=()
EXT_URLS=()

setup_load_extension_catalog() {
  local extensions_file="$1"
  EXT_NAMES=()
  EXT_DESCS=()
  EXT_CMDS=()
  EXT_HINTS=()
  EXT_URLS=()

  local local_name=""
  local local_desc=""
  local local_cmd=""
  local local_hint=""
  local local_url=""
  local line

  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
      if [[ -n "$local_name" ]]; then
        EXT_NAMES+=("$local_name")
        EXT_DESCS+=("$local_desc")
        EXT_CMDS+=("$local_cmd")
        EXT_HINTS+=("$local_hint")
        EXT_URLS+=("$local_url")
      fi
      local_name="${BASH_REMATCH[1]}"
      local_name="${local_name#\"}"
      local_name="${local_name%\"}"
      local_desc=""
      local_cmd=""
      local_hint=""
      local_url=""
    elif [[ "$line" =~ ^[[:space:]]*description:[[:space:]]*(.*) ]]; then
      local_desc="${BASH_REMATCH[1]}"
      local_desc="${local_desc#\"}"
      local_desc="${local_desc%\"}"
    elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*(.*) ]]; then
      local_cmd="${BASH_REMATCH[1]}"
      local_cmd="${local_cmd#\"}"
      local_cmd="${local_cmd%\"}"
    elif [[ "$line" =~ ^[[:space:]]*install_hint:[[:space:]]*(.*) ]]; then
      local_hint="${BASH_REMATCH[1]}"
      local_hint="${local_hint#\"}"
      local_hint="${local_hint%\"}"
    elif [[ "$line" =~ ^[[:space:]]*project_url:[[:space:]]*(.*) ]]; then
      local_url="${BASH_REMATCH[1]}"
      local_url="${local_url#\"}"
      local_url="${local_url%\"}"
    fi
  done <"$extensions_file"

  if [[ -n "$local_name" ]]; then
    EXT_NAMES+=("$local_name")
    EXT_DESCS+=("$local_desc")
    EXT_CMDS+=("$local_cmd")
    EXT_HINTS+=("$local_hint")
    EXT_URLS+=("$local_url")
  fi
}

setup_print_extension_catalog() {
  local i hint hint_line first_line
  for i in "${!EXT_NAMES[@]}"; do
    hint="${EXT_HINTS[$i]//\\n/$'\n'}"
    printf "  %d. %s — %s\n" "$((i + 1))" "${EXT_NAMES[$i]}" "${EXT_DESCS[$i]}"
    first_line=true
    while IFS= read -r hint_line || [[ -n "$hint_line" ]]; do
      if $first_line; then
        printf "     Install: %s\n" "$hint_line"
        first_line=false
      else
        printf "              %s\n" "$hint_line"
      fi
    done <<<"$hint"
    [[ -n "${EXT_URLS[$i]}" ]] && printf "     Project: %s\n" "${EXT_URLS[$i]}"
    echo ""
  done
}

setup_collect_extension_selection() {
  local selection_ref="$1"
  local selected_input=""

  if [[ "$YES" != "true" && "$HAS_TTY" == "true" ]]; then
    printf "${CYAN}  Enter numbers to enable (space-separated), 'all', or press ENTER to skip: ${NC}" >/dev/tty
    read -r selected_input </dev/tty
  elif [[ "$YES" != "true" ]]; then
    info "No TTY detected; skipping interactive extension selection"
  fi
  echo ""

  printf -v "$selection_ref" '%s' "$selected_input"
}

setup_enable_selected_extensions() {
  local extensions_file="$1"
  local selection="$2"

  if [[ -z "$selection" ]]; then
    info "No extensions enabled — edit clare/extensions.yml later to enable"
    return 0
  fi

  local enable_idx=()
  local i token idx ext cmd hint
  if [[ "$selection" == "all" ]]; then
    for i in "${!EXT_NAMES[@]}"; do
      enable_idx+=("$i")
    done
  else
    for token in $selection; do
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        idx=$((token - 1))
        if [[ $idx -ge 0 && $idx -lt ${#EXT_NAMES[@]} ]]; then
          enable_idx+=("$idx")
        else
          warn "No extension at position $token — skipped"
        fi
      fi
    done
  fi

  for idx in "${enable_idx[@]}"; do
    ext="${EXT_NAMES[$idx]}"
    cmd="${EXT_CMDS[$idx]:-$ext}"
    hint="${EXT_HINTS[$idx]:-check the extensions.yml for install instructions}"

    if [[ "${hint,,}" == *"built-in"* ]] || command -v "$cmd" &>/dev/null; then
      setup_set_extension_enabled_state "$extensions_file" "$ext" "true"
      success "Enabled extension: $ext"
    elif ask_yn "Enable $ext without installing? (verify-ci.sh will remind you)" "n"; then
      setup_set_extension_enabled_state "$extensions_file" "$ext" "true"
      success "Enabled extension: $ext (not yet installed)"
    else
      info "Skipped $ext"
    fi
  done
}

setup_step_extensions() {
  local extensions_file="$1"
  local latest_extensions_file="$2"
  local setup_target="$3"

  header "CLARE Setup — Step 5: Extensions [optional]"
  echo "CLARE extensions add optional tool checks to verify-ci.sh."
  echo ""
  if [[ ! -f "$extensions_file" ]]; then
    info "No extensions.yml found — extensions available after install"
    return 0
  fi

  setup_maybe_migrate_legacy_extensions "$extensions_file" "$latest_extensions_file" "$setup_target"
  setup_load_extension_catalog "$extensions_file"
  setup_print_extension_catalog

  local selection=""
  setup_collect_extension_selection selection
  setup_enable_selected_extensions "$extensions_file" "$selection"
}

CLARE_NEXT_STATUS="skipped"

write_clare_next_file() {
  local setup_target="$1"
  local setup_source_root="$2"
  local project_name="$3"
  local next_path="$setup_target/CLARE-NEXT.md"
  local scanner="$setup_source_root/install/clare/scripts/clare-env-scan.sh"
  local scan_file
  scan_file="$(mktemp)"

  if [[ -f "$scanner" ]]; then
    if ! (cd "$setup_target" && bash "$scanner" --json >"$scan_file"); then
      warn "Could not run CLARE readiness scanner; writing a minimal CLARE-NEXT.md"
      printf '%s\n' '{"detectedSurfaces":[],"verifiedSurfaces":[],"coverageGaps":[],"agentPrompts":[]}' >"$scan_file"
    fi
  else
    warn "CLARE readiness scanner not found; writing a minimal CLARE-NEXT.md"
    printf '%s\n' '{"detectedSurfaces":[],"verifiedSurfaces":[],"coverageGaps":[],"agentPrompts":[]}' >"$scan_file"
  fi

  NEXT_PATH="$next_path" SCAN_FILE="$scan_file" PROJECT_NAME="$project_name" INSTALLED_SKILLS="$SETUP_INSTALLED_SKILLS" python3 - <<'PYNEXT'
import json
import os
from pathlib import Path

begin = '<!-- CLARE-NEXT:BEGIN -->'
end = '<!-- CLARE-NEXT:END -->'
path = Path(os.environ['NEXT_PATH'])
project = os.environ.get('PROJECT_NAME') or path.parent.name
installed_skills = os.environ.get('INSTALLED_SKILLS', '').strip()
scan_path = Path(os.environ['SCAN_FILE'])
try:
    scan = json.loads(scan_path.read_text())
except Exception:
    scan = {'detectedSurfaces': [], 'verifiedSurfaces': [], 'coverageGaps': [], 'agentPrompts': []}

def surface_line(item):
    kind = item.get('kind') or 'surface'
    name = item.get('name') or '(unnamed)'
    rel = item.get('path') or '(unknown path)'
    cmd = item.get('command') or ''
    line = f"- `{kind}`: **{name}** in `{rel}`"
    if cmd:
        line += f" -> `{cmd}`"
    return line

detected = scan.get('detectedSurfaces') or []
gaps = scan.get('coverageGaps') or []
verified = scan.get('verifiedSurfaces') or []
prompts = scan.get('agentPrompts') or []
deploy_prompt = prompts[0].get('prompt') if prompts else 'Ask your agent to inspect this repository and wire project-specific checks into CLARE so ./clare/verify-ci.sh matches your deployment gates.'
autonomy_prompt = """Analyze this repository and create clare/autonomy.yml for CLARE. Include module boundaries with path, level (full-autonomy/supervised/humans-only), and reason for each entry, ending with a wildcard default. Also add 3-8 sources_of_truth entries. Then validate the YAML and show the proposed file content."""

content = []
content.append('# CLARE Next Steps')
content.append('')
content.append(begin)
content.append('')
content.append(f'Generated for **{project}**. This file is a short checklist for finishing CLARE setup with your agent. You can edit or delete it after setup.')
content.append('')
content.append('## 1. Review What CLARE Found')
content.append('')
if detected:
    for item in detected[:20]:
        content.append(surface_line(item))
    if len(detected) > 20:
        content.append(f'- ... {len(detected) - 20} more detected surfaces. Run `bash clare/scripts/clare-env-scan.sh --json` for the full report if that helper is installed.')
else:
    content.append('- No common build/test/deploy surfaces were detected by the readiness scanner.')
content.append('')
content.append('## 2. Close Coverage Gaps')
content.append('')
if gaps:
    content.append('These likely gates are not obviously covered by `clare/verify-ci.sh` or `clare/verify-local.sh`:')
    content.append('')
    for item in gaps[:12]:
        content.append(surface_line(item))
    if len(gaps) > 12:
        content.append(f'- ... {len(gaps) - 12} more likely gaps.')
else:
    content.append('- No obvious deployment parity gaps were found. Ask your agent to confirm before trusting automation fully.')
if verified:
    content.append('')
    content.append(f'Already referenced by CLARE verification: {len(verified)} surface(s).')
content.append('')
content.append('## 3. Copy/Paste Agent Prompts')
content.append('')
content.append('### Deployment parity')
content.append('')
content.append('```text')
content.append(deploy_prompt)
content.append('```')
content.append('')
content.append('### Autonomy boundaries')
content.append('')
content.append('```text')
content.append(autonomy_prompt)
content.append('```')
content.append('')
content.append('## 4. Run Verification')
content.append('')
content.append('After the agent updates project-owned CLARE files, run:')
content.append('')
content.append('```bash')
content.append('./clare/verify-ci.sh')
content.append('```')
if installed_skills:
    content.append('')
    content.append(f'Installed skills this run: `{installed_skills}`')
content.append('')
content.append(end)
content.append('')
content.append('## Your Notes')
content.append('')
content.append('Add project-specific notes below this line. Future installer runs preserve text outside the generated CLARE-NEXT block.')
content.append('')
new_block = '\n'.join(content).rstrip() + '\n'

generated_section = new_block[new_block.index(begin):new_block.index(end) + len(end)] + '\n'

if path.exists():
    old = path.read_text()
    if begin in old and end in old:
        before = old.split(begin, 1)[0]
        after = old.split(end, 1)[1]
        path.write_text(before.rstrip() + '\n\n' + generated_section + after)
    else:
        path.write_text(new_block + '\n---\n\n' + old)
else:
    path.write_text(new_block)
PYNEXT
  rm -f "$scan_file"
  CLARE_NEXT_STATUS="created"
}

setup_maybe_create_clare_next() {
  local setup_target="$1"
  local setup_source_root="$2"
  local project_name="$3"

  CLARE_NEXT_STATUS="skipped"
  if [[ "$YES" == "true" ]]; then
    write_clare_next_file "$setup_target" "$setup_source_root" "$project_name"
    success "Created CLARE-NEXT.md"
    return 0
  fi

  if [[ "$HAS_TTY" == "true" ]]; then
    if ask_yn "Create CLARE-NEXT.md with your personalized CLARE checklist and agent prompts? (recommended)" "y"; then
      write_clare_next_file "$setup_target" "$setup_source_root" "$project_name"
      success "Created CLARE-NEXT.md"
    else
      info "Skipped CLARE-NEXT.md creation"
    fi
    return 0
  fi

  info "Non-interactive setup without --yes: not creating CLARE-NEXT.md. Run setup again interactively, or run bash install/clare/scripts/clare-env-scan.sh --report from the CLARE source tree for guidance."
}

setup_print_next_steps() {
  echo ""
  echo "Next steps:"

  if [[ "$CLARE_NEXT_STATUS" == "created" ]]; then
    echo "1. Open CLARE-NEXT.md for your personalized checklist and copy/paste agent prompts."
    echo "2. Use your agent to close any deployment coverage gaps it lists."
    echo "3. Run ./clare/verify-ci.sh in your project."
    return 0
  fi

  echo "CLARE-NEXT.md was not created, so these prompts are printed here only."
  echo "Run setup again interactively or with --yes when you want the durable checklist."
  echo ""

  if [[ " $SETUP_INSTALLED_SKILLS " == *" autonomy-bootstrap "* ]]; then
    echo "1. Open your AI assistant (Cursor, Copilot Chat, Claude, etc.)."
    echo "2. Copy/paste this prompt to generate project-specific autonomy rules:"
    echo ""
    echo "Analyze this repository and create clare/autonomy.yml for CLARE."
    echo "Include module boundaries with path, level (full-autonomy/supervised/humans-only),"
    echo "and reason for each entry, ending with a wildcard default. Also add 3-8"
    echo "sources_of_truth entries (concept, source_of_truth, defined_in, note)."
    echo "Then validate the YAML and show the proposed file content."
    echo ""
    echo "3. Review clare/autonomy.yml for your project specifics."
    echo "4. Run ./clare/verify-ci.sh in your project."
    return 0
  fi

  echo "1. Review clare/autonomy.yml for your project specifics."
  echo "2. Run ./clare/verify-ci.sh in your project."
}

run_setup_flow() {
  local setup_target="$1"
  local setup_source_root="$2"
  local is_fresh_install="${3:-false}"

  local skills_dir prompts_dir extensions_file latest_extensions_file
  local claude_commands_dir cursor_rules_dir vscode_prompts_dir codex_skills_dir

  skills_dir="$setup_source_root/install/clare/templates/skills"
  prompts_dir="$setup_target/.github/prompts"
  claude_commands_dir="$setup_target/.claude/commands"
  cursor_rules_dir="$setup_target/.cursor/rules"
  vscode_prompts_dir="$setup_target/.vscode/prompts"
  codex_skills_dir="$setup_target/.codex/skills"
  extensions_file="$setup_target/clare/extensions.yml"
  latest_extensions_file="$setup_source_root/clare/extensions.yml"
  SETUP_INSTALLED_SKILLS=""

  header "CLARE Setup — Step 1: Project Info"
  local project_name default_project_name
  default_project_name="$(basename "$(cd "$setup_target" && pwd)")"
  project_name="$(ask "Project name" "$default_project_name")"
  [[ -n "$project_name" ]] || project_name="$default_project_name"
  echo ""
  info "Setting up CLARE for: $project_name"

  header "CLARE Setup — Step 2: Autonomy Boundaries"
  mkdir -p "$setup_target/clare"
  if [[ "$is_fresh_install" == "true" || ! -f "$setup_target/clare/autonomy.yml" ]]; then
    copy_file_if_missing "$setup_source_root/install/clare/autonomy.yml" "$setup_target/clare/autonomy.yml"
    success "Created starter clare/autonomy.yml"
  else
    info "Keeping existing clare/autonomy.yml"
  fi
  sync_autonomy_project_name "$setup_target/clare/autonomy.yml" "$project_name"

  header "CLARE Setup — Step 3: Script Permissions"
  if [[ -d "$setup_target/clare" ]]; then
    chmod +x "$setup_target/clare/"*.sh 2>/dev/null || true
    success "Ensured scripts are executable"
  fi

  setup_step_install_skills "$skills_dir" "$prompts_dir" "$claude_commands_dir" "$cursor_rules_dir" "$vscode_prompts_dir" "$codex_skills_dir" "$setup_target"
  setup_step_extensions "$extensions_file" "$latest_extensions_file" "$setup_target"

  setup_maybe_create_clare_next "$setup_target" "$setup_source_root" "$project_name"

  header "Setup Complete"
  success "CLARE is configured for: $project_name"
  if [[ -n "$SETUP_INSTALLED_SKILLS" ]]; then
    echo "Installed skills:$SETUP_INSTALLED_SKILLS"
  fi

  setup_print_next_steps
}

# Guard a value-taking flag: error out instead of silently mis-parsing when the
# value is missing. Without this, a trailing value flag (e.g. `--install-skill`
# as the last argument) makes `shift 2` fail on a single-element list, leaving
# $1 unchanged and spinning the arg loop forever.
require_flag_value() {
  local flag="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == -* ]]; then
    error "$flag requires a value"
    usage
    exit "$EXIT_USAGE"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      require_flag_value "--target" "${2:-}"
      TARGET_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --yes)
      YES=true
      shift
      ;;
    --auto-update)
      AUTO_UPDATE=true
      shift
      ;;
    --no-setup)
      RUN_SETUP=false
      shift
      ;;
    --setup-only)
      SETUP_ONLY=true
      shift
      ;;
    --install-skill)
      require_flag_value "--install-skill" "${2:-}"
      INSTALL_SKILLS="$2"
      shift 2
      ;;
    --update)
      UPDATE=true
      shift
      ;;
    --install-examples)
      require_flag_value "--install-examples" "${2:-}"
      INSTALL_EXAMPLES_PATH="$2"
      shift 2
      ;;
    --extract)
      require_flag_value "--extract" "${2:-}"
      EXTRACT_PATH="$2"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --*)
      error "Unknown argument: $1"
      usage
      exit "$EXIT_USAGE"
      ;;
    *)
      if [[ -n "$TARGET_DIR" ]]; then
        error "Unexpected argument: $1"
        usage
        exit "$EXIT_USAGE"
      fi
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$PWD"
fi

EMBEDDED_MODE=false
if has_embedded_payload; then
  EMBEDDED_MODE=true
fi

INSTALLER_VERSION="$(detect_installer_version)"
header "CLARE AI-Assisted Development Framework
  v${INSTALLER_VERSION}"

if [[ -n "$EXTRACT_PATH" && ("$TARGET_DIR" != "$PWD" || "$DRY_RUN" == "true" || "$YES" == "true") ]]; then
  error "--extract cannot be combined with --target/positional target, --dry-run, or --yes"
  exit "$EXIT_USAGE"
fi

if [[ "$AUTO_UPDATE" == "true" && "$UPDATE" != "true" ]]; then
  error "--auto-update requires --update"
  exit "$EXIT_USAGE"
fi

if [[ -n "$EXTRACT_PATH" && -n "$INSTALL_EXAMPLES_PATH" ]]; then
  error "--extract cannot be combined with --install-examples"
  exit "$EXIT_USAGE"
fi

if [[ "$SETUP_ONLY" == "true" && (-n "$EXTRACT_PATH" || -n "$INSTALL_EXAMPLES_PATH") ]]; then
  error "--setup-only cannot be combined with --extract or --install-examples"
  exit "$EXIT_USAGE"
fi

if [[ -n "$INSTALL_EXAMPLES_PATH" && ("$TARGET_DIR" != "$PWD" || "$DRY_RUN" == "true" || "$YES" == "true" || "$RUN_SETUP" == "false") ]]; then
  error "--install-examples cannot be combined with --target/positional target, --dry-run, --yes, or --no-setup"
  exit "$EXIT_USAGE"
fi

if [[ -n "$EXTRACT_PATH" && "$EMBEDDED_MODE" != "true" ]]; then
  error "--extract requires an embedded payload (release installer artifact)"
  exit "$EXIT_USAGE"
fi

if [[ -n "$EXTRACT_PATH" ]]; then
  if [[ -e "$EXTRACT_PATH" ]]; then
    if [[ -d "$EXTRACT_PATH" && -n "$(ls -A "$EXTRACT_PATH" 2>/dev/null)" && "$FORCE" != "true" ]]; then
      error "Extraction path exists and is not empty. Use --force to allow overwrite."
      exit "$EXIT_EXTRACT"
    fi
    if [[ ! -d "$EXTRACT_PATH" ]]; then
      error "Extraction path exists and is not a directory: $EXTRACT_PATH"
      exit "$EXIT_EXTRACT"
    fi
  fi

  mkdir -p "$EXTRACT_PATH"
  extract_payload "$EXTRACT_PATH" || {
    error "Extraction failed"
    exit "$EXIT_EXTRACT"
  }

  info "Extraction complete: $EXTRACT_PATH"
  echo "RESULT success mode=extract"
  exit 0
fi

SOURCE_ROOT=""
if [[ "$EMBEDDED_MODE" == "true" ]]; then
  command -v tar >/dev/null 2>&1 || {
    error "Required tool not found: tar"
    exit "$EXIT_PREFLIGHT"
  }
  command -v mktemp >/dev/null 2>&1 || {
    error "Required tool not found: mktemp"
    exit "$EXIT_PREFLIGHT"
  }

  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT INT TERM

  extract_payload "$WORK_DIR" || {
    error "Failed to extract installer payload"
    exit "$EXIT_EXTRACT"
  }

  SOURCE_ROOT="$WORK_DIR/clare-dist"
  [[ -d "$SOURCE_ROOT" ]] || {
    error "Extracted payload is missing clare-dist"
    exit "$EXIT_RUNTIME"
  }
else
  SOURCE_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
fi

if [[ -n "$INSTALL_EXAMPLES_PATH" ]]; then
  EXAMPLES_SOURCE="$SOURCE_ROOT/install/clare/examples"
  [[ -d "$EXAMPLES_SOURCE" ]] || {
    error "Examples source not found: $EXAMPLES_SOURCE"
    exit "$EXIT_RUNTIME"
  }

  if [[ -e "$INSTALL_EXAMPLES_PATH" ]]; then
    if [[ -d "$INSTALL_EXAMPLES_PATH" && -n "$(ls -A "$INSTALL_EXAMPLES_PATH" 2>/dev/null)" && "$FORCE" != "true" ]]; then
      error "Examples path exists and is not empty. Use --force to allow overwrite."
      exit "$EXIT_EXTRACT"
    fi
    if [[ ! -d "$INSTALL_EXAMPLES_PATH" ]]; then
      error "Examples path exists and is not a directory: $INSTALL_EXAMPLES_PATH"
      exit "$EXIT_EXTRACT"
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "Dry run: would copy clare/examples/* to $INSTALL_EXAMPLES_PATH"
    echo "RESULT success mode=install-examples dry-run=true"
    exit 0
  fi

  mkdir -p "$INSTALL_EXAMPLES_PATH"
  cp -r "$EXAMPLES_SOURCE/." "$INSTALL_EXAMPLES_PATH/"
  info "Examples installed: $INSTALL_EXAMPLES_PATH"
  echo "RESULT success mode=install-examples"
  exit 0
fi

if [[ "$SETUP_ONLY" == "true" ]]; then
  ensure_git_repo "$TARGET_DIR" || exit "$EXIT_PREFLIGHT"
  warn_if_repo_dirty_before_install "$TARGET_DIR" || exit "$EXIT_PREFLIGHT"
  setup_only_is_fresh="false"
  if has_legacy_clear_install "$TARGET_DIR" && ! has_clare_install "$TARGET_DIR"; then
    error "Legacy CLARE install detected at clear/. Run with --update before --setup-only."
    exit "$EXIT_USAGE"
  fi
  has_clare_install "$TARGET_DIR" || setup_only_is_fresh="true"
  run_setup_flow "$TARGET_DIR" "$SOURCE_ROOT" "$setup_only_is_fresh"
  maybe_commit_clare_changes "$TARGET_DIR"
  echo "RESULT success mode=setup-only"
  exit 0
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  error "Target directory does not exist: $TARGET_DIR"
  exit "$EXIT_RUNTIME"
fi

ensure_git_repo "$TARGET_DIR" || exit "$EXIT_PREFLIGHT"
warn_if_repo_dirty_before_install "$TARGET_DIR" || exit "$EXIT_PREFLIGHT"

if ! command -v jq >/dev/null 2>&1; then
  error "jq is required to merge CLARE-managed .vscode/*.json files"
  exit "$EXIT_PREFLIGHT"
fi

is_fresh_install="false"
has_current_install=false
has_legacy_install=false
if has_clare_install "$TARGET_DIR"; then
  has_current_install=true
fi
if has_legacy_clear_install "$TARGET_DIR"; then
  has_legacy_install=true
fi

if [[ "$has_current_install" == "true" || "$has_legacy_install" == "true" ]]; then
  if [[ "$UPDATE" != "true" ]]; then
    error "CLARE is already installed in this project."
    error "To update, re-run with --update:"
    error "  $0 --target $TARGET_DIR --update"
    exit "$EXIT_USAGE"
  fi
  if [[ "$has_legacy_install" == "true" ]]; then
    migrate_legacy_clear_install "$TARGET_DIR"
  fi
  info "Detected existing CLARE project. Running update workflow."
else
  is_fresh_install="true"
  info "Detected fresh target. Running bootstrap workflow."
fi

if [[ "$DRY_RUN" == "true" ]]; then
  info "Dry run: listing file changes (+ new, ~ changed):"
fi

# CLARE-managed files (always updated).
# These are framework-owned assets that should track the installer version.
copy_file_update "$SOURCE_ROOT/clare/verify-ci.sh" "$TARGET_DIR/clare/verify-ci.sh"
# clare/scripts/clare2-install-hooks.sh (run by install_clare2_corpus_capture
# below) copies clare2-capture-event.sh out of clare/templates/scripts/, so
# clare/templates must be synced first.
copy_dir_update "$SOURCE_ROOT/install/clare/templates" "$TARGET_DIR/clare/templates"
# clare/verify-ci.sh emits CLARE2 corpus signals; keep its capture-event/
# hook-install scripts and provider hooks in sync.
install_clare2_corpus_capture "$SOURCE_ROOT" "$TARGET_DIR" || exit "$EXIT_ABORT"
copy_file_update "$SOURCE_ROOT/clare/principles.md" "$TARGET_DIR/clare/principles.md"
copy_dir_update "$SOURCE_ROOT/install/.github" "$TARGET_DIR/.github" "prompts"
copy_dir_update "$SOURCE_ROOT/install/.cursor" "$TARGET_DIR/.cursor"
copy_dir_update "$SOURCE_ROOT/install/.claude" "$TARGET_DIR/.claude"
# .vscode/{settings,extensions,tasks}.json are team-customizable; merge
# CLARE's recommended keys/entries instead of overwriting them.
copy_dir_update "$SOURCE_ROOT/install/.vscode" "$TARGET_DIR/.vscode" "" \
  "settings.json extensions.json tasks.json"
merge_or_copy_vscode_json "$SOURCE_ROOT/install/.vscode/settings.json" "$TARGET_DIR/.vscode/settings.json" settings
merge_or_copy_vscode_json "$SOURCE_ROOT/install/.vscode/extensions.json" "$TARGET_DIR/.vscode/extensions.json" extensions
merge_or_copy_vscode_json "$SOURCE_ROOT/install/.vscode/tasks.json" "$TARGET_DIR/.vscode/tasks.json" tasks
copy_file_update "$SOURCE_ROOT/install/root/CLAUDE.md" "$TARGET_DIR/CLAUDE.md"
copy_file_update "$SOURCE_ROOT/install/root/AGENTS.md" "$TARGET_DIR/AGENTS.md"
copy_file_update "$SOURCE_ROOT/install/root/.cursorrules" "$TARGET_DIR/.cursorrules"
copy_dir_update "$SOURCE_ROOT/install/clare/examples" "$TARGET_DIR/clare/examples"
copy_dir_update "$SOURCE_ROOT/install/clare/docs" "$TARGET_DIR/clare/docs"

# Project-owned files (create-if-missing).
# These are user-customizable entry points and should not be overwritten.
copy_file_if_missing "$SOURCE_ROOT/install/clare/verify-local.sh" "$TARGET_DIR/clare/verify-local.sh"
copy_file_if_missing "$SOURCE_ROOT/install/clare/autonomy.yml" "$TARGET_DIR/clare/autonomy.yml"
ensure_clare2_autonomy_boundaries "$TARGET_DIR"
copy_file_if_missing "$SOURCE_ROOT/clare/extensions.yml" "$TARGET_DIR/clare/extensions.yml"
copy_file_if_missing "$SOURCE_ROOT/install/root/.gitignore" "$TARGET_DIR/.gitignore"
ensure_gitignore_entry "$TARGET_DIR/.gitignore" "CLARE-NEXT.md" "CLARE generated onboarding checklist (local/ephemeral)"

if [[ "$is_fresh_install" != "true" ]]; then
  update_installed_extensions "$TARGET_DIR/clare/extensions.yml" "$SOURCE_ROOT/clare/extensions.yml" "$TARGET_DIR"
fi

# Keep already-installed generic skills current.
if [[ -d "$TARGET_DIR/.github/prompts" ]]; then
  while IFS= read -r prompt_file; do
    skill_name="$(basename "$prompt_file" .prompt.md)"
    src_skill=""
    if [[ -f "$SOURCE_ROOT/install/clare/templates/skills/${skill_name}.md" ]]; then
      src_skill="$SOURCE_ROOT/install/clare/templates/skills/${skill_name}.md"
    fi
    if [[ -n "$src_skill" ]]; then
      prompt_update_file "$src_skill" "$prompt_file" || exit "$EXIT_ABORT"
    fi
  done < <(find "$TARGET_DIR/.github/prompts" -name "*.prompt.md" -type f | sort)
fi

if [[ -d "$TARGET_DIR/.codex/skills" ]]; then
  while IFS= read -r skill_file; do
    skill_name="$(basename "$(dirname "$skill_file")")"
    src_skill=""
    if [[ -f "$SOURCE_ROOT/install/clare/templates/skills/${skill_name}.md" ]]; then
      src_skill="$SOURCE_ROOT/install/clare/templates/skills/${skill_name}.md"
    fi
    if [[ -n "$src_skill" ]]; then
      prompt_update_file "$src_skill" "$skill_file" || exit "$EXIT_ABORT"
    fi
  done < <(find "$TARGET_DIR/.codex/skills" -path "*/SKILL.md" -type f | sort)
fi

if [[ -d "$TARGET_DIR/clare" ]]; then
  chmod +x "$TARGET_DIR/clare/"*.sh 2>/dev/null || true
fi

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$RUN_SETUP" == "true" ]]; then
    info "Dry run: setup flow would run after file updates"
  else
    info "Dry run: setup flow would be skipped (--no-setup)"
  fi
  echo "RESULT success mode=install-or-update dry-run=true"
  exit 0
fi

if [[ "$RUN_SETUP" == "true" ]]; then
  run_setup_flow "$TARGET_DIR" "$SOURCE_ROOT" "$is_fresh_install"
else
  info "Setup wizard skipped (--no-setup)."
fi

maybe_commit_clare_changes "$TARGET_DIR"
exit 0
