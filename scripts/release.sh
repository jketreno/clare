#!/usr/bin/env bash
# =============================================================================
# CLARE release.sh — Make a release with tagged source and GitHub artifacts
# =============================================================================
# Usage:
#   ./scripts/release.sh
#   ./scripts/release.sh --version 1.2.3 --notes-file docs/release-notes/v1.2.3.md
#   ./scripts/release.sh --dry-run
#
# Exit codes:
#   2 - Invalid usage, input, or user-aborted preflight prompt
#   3 - Preflight gate failed (git state, branch, verify, auth, duplicate tag)
#   4 - Expected release artifact missing after build
#   6 - GitHub release publish failed after tag push
# =============================================================================

set -euo pipefail

SCRIPT_SELF="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SELF")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./release-lib.sh
source "$SCRIPT_DIR/release-lib.sh"

VERSION=""
DRY_RUN=false
SKIP_VERIFY=false
YES=false
NOTES_FILE=""
NOTES_TEMPLATE="$PROJECT_ROOT/docs/release-notes-template.md"
SIGNING_KEY=""
SIGN_ARTIFACTS=true
KEY_PATH="docs/keys/clare-release-signing-public.asc"
FINGERPRINT_FILE="$PROJECT_ROOT/docs/keys/clare-release-signing-fingerprint.txt"
TEMP_NOTES_FILE=""

cleanup_release_temp_files() {
  if [[ -n "$TEMP_NOTES_FILE" && -f "$TEMP_NOTES_FILE" ]]; then
    rm -f "$TEMP_NOTES_FILE"
  fi
}

trap cleanup_release_temp_files EXIT

generate_release_notes() {
  local version="$1"
  local output_file="$2"
  local template_file="$3"
  local key_path="$4"
  local fingerprint_file="$5"
  local include_signature="$6"

  local release_base="https://github.com/jketreno/clare/releases/download/v${version}"
  local key_url="https://raw.githubusercontent.com/jketreno/clare/v${version}/${key_path}"

  local fingerprint="(unavailable)"
  if [[ -f "$fingerprint_file" ]]; then
    fingerprint="$(tr -s ' ' <"$fingerprint_file" | sed 's/^ //; s/ $//')"
  fi

  local signature_section
  if [[ "$include_signature" == "true" ]]; then
    signature_section="gpg --verify clare-installer-v${version}.sha256.asc clare-installer-v${version}.sha256\nsha256sum -c clare-installer-v${version}.sha256"
  else
    signature_section="This release was generated in break-glass mode without detached signature artifacts (--no-sign)."
  fi

  local download_section="curl -fsSLO ${release_base}/clare-installer-v${version}.sh\ncurl -fsSLO ${release_base}/clare-installer-v${version}.sha256\ncurl -fsSLO ${release_base}/clare-installer-v${version}.sha256.asc\ncurl -fsSL -o clare-release-signing-public.asc ${key_url}\ngpg --import clare-release-signing-public.asc"

  if [[ -f "$template_file" ]]; then
    awk \
      -v version="$version" \
      -v key_path="$key_path" \
      -v fingerprint="$fingerprint" \
      -v download_section="$download_section" \
      -v signature_section="$signature_section" \
      '{
        gsub(/\{\{VERSION\}\}/, version)
        gsub(/\{\{KEY_PATH\}\}/, key_path)
        gsub(/\{\{FINGERPRINT\}\}/, fingerprint)
        gsub(/\{\{DOWNLOAD_SECTION\}\}/, download_section)
        gsub(/\{\{SIGNATURE_SECTION\}\}/, signature_section)
        print
      }' "$template_file" >"$output_file"
  else
    cat >"$output_file" <<EOF
# CLARE v${version}

## Release Artifacts

- clare-installer-v${version}.sh
- clare-installer-v${version}.sha256
- clare-installer-v${version}.sha256.asc

## Verify Before Running

Public key file: ${key_path}
Fingerprint: ${fingerprint}

curl -fsSLO ${release_base}/clare-installer-v${version}.sh
curl -fsSLO ${release_base}/clare-installer-v${version}.sha256
curl -fsSLO ${release_base}/clare-installer-v${version}.sha256.asc
curl -fsSL -o clare-release-signing-public.asc ${key_url}
gpg --import clare-release-signing-public.asc

${signature_section}

Do not run the installer unless verification succeeds.
EOF
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=true
      shift
      ;;
    --yes)
      YES=true
      shift
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --notes-template)
      NOTES_TEMPLATE="${2:-}"
      shift 2
      ;;
    --signing-key)
      SIGNING_KEY="${2:-}"
      shift 2
      ;;
    --no-sign)
      SIGN_ARTIFACTS=false
      shift
      ;;
    --help | -h)
      cat <<'EOF'
Usage: ./scripts/release.sh [options]

Options:
  --version <semver>   Override VERSION file value
  --dry-run            Print actions without mutating git/GitHub
  --skip-verify        Skip ./clare/verify-ci.sh (break-glass; bypasses local CI gate)
  --yes                Auto-confirm interactive prompts
  --notes-file <path>  File to use for GitHub release notes
  --notes-template <path> Template file used when --notes-file is omitted
  --signing-key <id>   GPG key ID/fingerprint for checksum signature
  --no-sign            Skip checksum signature generation (break-glass; artifacts are unsigned)
  --help               Show this help
EOF
      exit 0
      ;;
    *)
      rl_die 2 "Unknown argument: $1"
      ;;
  esac
done

cd "$PROJECT_ROOT"

rl_require_command git "Install git"
rl_require_command gh "Install GitHub CLI"
rl_require_command sha256sum "Install coreutils"
rl_require_command tar "Install tar"
if [[ "$SIGN_ARTIFACTS" == "true" ]]; then
  rl_require_command gpg "Install GnuPG"
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(rl_read_version_file "$PROJECT_ROOT/VERSION")"
fi
rl_validate_semver "$VERSION" || rl_die 2 "Invalid semantic version: $VERSION"

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  rl_die 2 "Notes file not found: $NOTES_FILE"
fi
if [[ -z "$NOTES_FILE" && ! -f "$NOTES_TEMPLATE" ]]; then
  rl_warn "Release notes template not found: $NOTES_TEMPLATE"
  rl_warn "Falling back to built-in generated notes."
fi

if [[ "$SKIP_VERIFY" == "true" ]]; then
  rl_warn "--skip-verify enabled. This should only be used in emergencies."
fi
if [[ "$SIGN_ARTIFACTS" == "false" ]]; then
  rl_warn "--no-sign enabled. Release artifacts will not include detached signatures."
fi

if [[ "$DRY_RUN" != "true" && "$YES" != "true" ]]; then
  echo "About to create release v$VERSION from branch 'main'."
  read -r -p "Continue? [y/N] " reply
  if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
    rl_die 2 "Release aborted by user"
  fi
fi

rl_require_clean_tree
rl_require_main_branch "main"

if rl_tag_exists "v$VERSION"; then
  rl_die 3 "Tag already exists: v$VERSION"
fi

if [[ "$DRY_RUN" != "true" ]]; then
  gh auth status >/dev/null 2>&1 || rl_die 3 "gh auth status failed. Run 'gh auth login' first."
fi

if [[ "$SKIP_VERIFY" != "true" ]]; then
  rl_info "Running verify-ci gate"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN: ./clare/verify-ci.sh"
  else
    ./clare/verify-ci.sh
  fi
fi

OUTPUT_DIR="$PROJECT_ROOT/dist/release/v$VERSION"
mkdir -p "$OUTPUT_DIR"

build_cmd=("$PROJECT_ROOT/scripts/build-release-installer.sh" "--version" "$VERSION" "--output-dir" "$OUTPUT_DIR")
if [[ "$SIGN_ARTIFACTS" == "false" ]]; then
  build_cmd+=("--no-sign")
fi
if [[ -n "$SIGNING_KEY" ]]; then
  build_cmd+=("--signing-key" "$SIGNING_KEY")
fi

rl_info "Building release artifacts"
rl_run "$DRY_RUN" "${build_cmd[@]}"

INSTALLER_PATH="$OUTPUT_DIR/clare-installer-v$VERSION.sh"
CHECKSUM_PATH="$OUTPUT_DIR/clare-installer-v$VERSION.sha256"
SIGNATURE_PATH="$OUTPUT_DIR/clare-installer-v$VERSION.sha256.asc"

if [[ "$DRY_RUN" != "true" ]]; then
  [[ -f "$INSTALLER_PATH" ]] || rl_die 4 "Missing installer artifact: $INSTALLER_PATH"
  [[ -f "$CHECKSUM_PATH" ]] || rl_die 4 "Missing checksum artifact: $CHECKSUM_PATH"
  if [[ "$SIGN_ARTIFACTS" == "true" ]]; then
    [[ -f "$SIGNATURE_PATH" ]] || rl_die 4 "Missing signature artifact: $SIGNATURE_PATH"
  fi
fi

if [[ -z "$NOTES_FILE" ]]; then
  TEMP_NOTES_FILE="$(mktemp)"
  generate_release_notes \
    "$VERSION" \
    "$TEMP_NOTES_FILE" \
    "$NOTES_TEMPLATE" \
    "$KEY_PATH" \
    "$FINGERPRINT_FILE" \
    "$SIGN_ARTIFACTS"
  NOTES_FILE="$TEMP_NOTES_FILE"
  rl_info "Generated release notes from template: $NOTES_TEMPLATE"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  rl_info "Release notes preview: $NOTES_FILE"
  echo "----- BEGIN RELEASE NOTES -----"
  cat "$NOTES_FILE"
  echo "----- END RELEASE NOTES -----"
fi

if [[ "$DRY_RUN" != "true" ]]; then
  rl_info "Release notes preview: $NOTES_FILE"
  echo "----- BEGIN RELEASE NOTES -----"
  cat "$NOTES_FILE"
  echo "----- END RELEASE NOTES -----"

  if [[ "$YES" != "true" ]]; then
    read -r -p "Edit release notes before publish? [y/N] " edit_reply
    if [[ "$edit_reply" == "y" || "$edit_reply" == "Y" ]]; then
      "${EDITOR:-vi}" "$NOTES_FILE"
      rl_info "Updated release notes preview"
      echo "----- BEGIN RELEASE NOTES -----"
      cat "$NOTES_FILE"
      echo "----- END RELEASE NOTES -----"
    fi

    read -r -p "Proceed with tag and publish using these notes? [y/N] " notes_reply
    if [[ "$notes_reply" != "y" && "$notes_reply" != "Y" ]]; then
      rl_die 2 "Release aborted before publish"
    fi
  fi
fi

rl_info "Creating and pushing git tag"
rl_run "$DRY_RUN" git tag -a "v$VERSION" -m "CLARE v$VERSION"
rl_run "$DRY_RUN" git push origin "v$VERSION"

release_assets=("$INSTALLER_PATH" "$CHECKSUM_PATH")
if [[ "$SIGN_ARTIFACTS" == "true" ]]; then
  release_assets+=("$SIGNATURE_PATH")
fi

gh_cmd=(gh release create "v$VERSION")
gh_cmd+=("${release_assets[@]}")
gh_cmd+=(--title "CLARE v$VERSION")
gh_cmd+=(--notes-file "$NOTES_FILE")

rl_info "Publishing GitHub release"
if [[ "$DRY_RUN" == "true" ]]; then
  printf 'DRY_RUN: '
  printf '%q ' "${gh_cmd[@]}"
  printf '\n'
else
  set +e
  "${gh_cmd[@]}"
  release_status=$?
  set -e
  if [[ "$release_status" -ne 0 ]]; then
    rl_error "GitHub release publish failed after tag push."
    rl_error "Manual recovery: delete local+remote tag if this release should be rolled back:"
    rl_error "  git tag -d v$VERSION"
    rl_error "  git push origin :refs/tags/v$VERSION"
    exit 6
  fi
fi

rl_ok "Release complete: v$VERSION"
