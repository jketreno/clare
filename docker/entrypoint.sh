#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
CLONE_DIR="/work/repo"

if [ -z "$REPO_URL" ]; then
  echo "ERROR: REPO_URL is not set. Provide the repository URL via -e REPO_URL=..."
  exit 2
fi

echo "Cloning $REPO_URL (branch: $BRANCH) into $CLONE_DIR"
if [ -d "$CLONE_DIR" ]; then
  rm -rf "$CLONE_DIR"
fi

# Only public HTTPS repositories are supported. SSH/private-repo support was removed.
case "$REPO_URL" in
  git@* | ssh://*)
    echo "ERROR: SSH-style repository URLs are not supported. Use a public HTTPS URL."
    exit 2
    ;;
esac

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$CLONE_DIR" || {
  echo "git clone failed"
  exit 3
}
cd "$CLONE_DIR"

CLARE_MOUNT="/work/host_clare"

if [ -f "$CLARE_MOUNT/README.md" ]; then
  echo "CLARE README found at $CLARE_MOUNT/README.md — following installer instructions"

  # Prefer running the bundled installer script from the mounted CLARE repo
  if [ -f "$CLARE_MOUNT/scripts/clare-installer.sh" ]; then
    echo "Found local installer script — running it against project at $CLONE_DIR"
    chmod +x "$CLARE_MOUNT/scripts/clare-installer.sh" || true
    bash "$CLARE_MOUNT/scripts/clare-installer.sh" --target "$CLONE_DIR" --yes || echo "CLARE installer (source) failed"

  else
    # Try to extract a release installer URL from the README and run it
    release_url=$(grep -o 'https://github.com/jketreno/clare/releases/download/[^/]*/clare-installer-v[0-9.]*\.sh' "$CLARE_MOUNT/README.md" | head -n 1 || true)
    if [ -n "$release_url" ]; then
      echo "Found release installer URL in README: $release_url"
      tmp_installer=$(mktemp /tmp/clare-installer.XXXXXX.sh)
      curl -fsSL -o "$tmp_installer" "$release_url" || {
        echo "Failed to download installer from $release_url"
        tmp_installer=""
      }
      if [ -n "$tmp_installer" ] && [ -f "$tmp_installer" ]; then
        chmod +x "$tmp_installer" || true
        "$tmp_installer" --target "$CLONE_DIR" --yes || echo "CLARE release installer failed"
        rm -f "$tmp_installer" || true
      fi
    else
      echo "No release installer URL found in README; falling back to cloning CLARE and running its installer"
      if command -v git >/dev/null 2>&1; then
        tmp_src=$(mktemp -d /tmp/clare-src.XXXXXX)
        git clone https://github.com/jketreno/clare "$tmp_src" || {
          echo "Failed to clone clare repo"
          tmp_src=""
        }
        if [ -n "$tmp_src" ] && [ -f "$tmp_src/scripts/clare-installer.sh" ]; then
          bash "$tmp_src/scripts/clare-installer.sh" --target "$CLONE_DIR" --yes || echo "CLARE installer (cloned) failed"
        fi
        rm -rf "$tmp_src" || true
      else
        echo "git not available; cannot fallback to cloning CLARE. Skipping CLARE install."
      fi
    fi
  fi
else
  echo "No CLARE README mounted at $CLARE_MOUNT — skipping CLARE installer step"
fi

# If this is a CLARE repo (has clare/verify-ci.sh), run it with --fast to validate installed scripts
verify_status="skipped"
if [ -f "clare/verify-ci.sh" ]; then
  echo "Found clare/verify-ci.sh — running with --fast to validate installation scripts"
  chmod +x clare/verify-ci.sh
  if bash clare/verify-ci.sh --fast; then
    verify_status="passed"
  else
    verify_status="failed"
  fi
else
  echo "No clare/verify-ci.sh found — skipping CLARE verification step"
fi

echo "=== Install smoke test completed (verify-ci.sh: $verify_status) ==="
case "$verify_status" in
  failed)
    echo "VERIFICATION FAILED: clare/verify-ci.sh reported failures. The install" >&2
    echo "is not validated. See the check output above for details." >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
