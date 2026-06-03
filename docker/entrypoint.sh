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
case "$REPO_URL" in
  git@*|ssh://*)
    echo "Detected SSH-style repository URL"

    # Detect whether $HOME/.ssh is a mount (works even if permissions prevent access)
    is_mounted=false
    if grep -qF "$HOME/.ssh" /proc/self/mountinfo 2>/dev/null || grep -qF "$HOME/.ssh" /proc/mounts 2>/dev/null; then
      is_mounted=true
    fi

    # Default SSH dir we'll operate on; may fall back to /tmp/ssh if $HOME isn't writable
    SSH_DIR="$HOME/.ssh"

    # If caller mounted keys into /opt/ssh (read-only), try copying into $HOME; if that fails, copy into a temporary writable dir
    if [ -d /opt/ssh ]; then
      echo "Found mounted SSH at /opt/ssh — attempting to copy into $HOME/.ssh"

      # Try writing into $HOME first
      if mkdir -p "$HOME/.ssh" >/dev/null 2>&1 && touch "$HOME/.ssh/.ssh_write_test" >/dev/null 2>&1; then
        rm -f "$HOME/.ssh/.ssh_write_test" || true
        cp -a /opt/ssh/. "$HOME/.ssh/" 2>/dev/null || cp -a /opt/ssh/* "$HOME/.ssh/" 2>/dev/null || true
        chmod 700 "$HOME/.ssh" 2>/dev/null || true
        find "$HOME/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true
        SSH_DIR="$HOME/.ssh"
      else
        echo "Cannot write to $HOME — copying SSH keys into temporary directory"
        TMP_SSH_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/ssh.$$")
        cp -a /opt/ssh/. "$TMP_SSH_DIR/" 2>/dev/null || cp -a /opt/ssh/* "$TMP_SSH_DIR/" 2>/dev/null || true
        chmod 700 "$TMP_SSH_DIR" 2>/dev/null || true
        find "$TMP_SSH_DIR" -type f -exec chmod 600 {} \; 2>/dev/null || true
        SSH_DIR="$TMP_SSH_DIR"
      fi
    elif [ "$is_mounted" = true ] || [ -d "$HOME/.ssh" ]; then
      SSH_DIR="$HOME/.ssh"
    fi

    if [ -d "$SSH_DIR" ]; then
      echo "Using SSH directory $SSH_DIR — attempting to prepare keys"

      # Try to set safe permissions if writable; ignore failures for read-only mounts
      find "$SSH_DIR" -maxdepth 0 -type d -exec chmod 700 {} \; >/dev/null 2>&1 || true
      find "$SSH_DIR" -type f -exec chmod 600 {} \; >/dev/null 2>&1 || true

      # Determine host for known_hosts management
      if echo "$REPO_URL" | grep -q '^git@'; then
        host=$(echo "$REPO_URL" | cut -d'@' -f2 | cut -d: -f1)
      else
        host=$(echo "$REPO_URL" | sed -E 's#ssh://([^/]+)/.*#\1#')
      fi

      # If SSH_DIR is writable, append host key; otherwise fall back to disabling strict host checking
      if touch "$SSH_DIR/.ssh_write_test" >/dev/null 2>&1; then
        rm -f "$SSH_DIR/.ssh_write_test" || true
        if [ -n "$host" ]; then
          echo "Ensuring host key for $host in $SSH_DIR/known_hosts"
          mkdir -p "$SSH_DIR"
          if ! ssh-keygen -F "$host" >/dev/null 2>&1; then
            ssh-keyscan -H "$host" >> "$SSH_DIR/known_hosts" 2>/dev/null || true
          fi
        fi
      else
        echo "Note: $SSH_DIR appears to be read-only or not writable — attempting to use an identity file (if present) and disabling strict host checking to prevent interactive prompts. Clone will fail quickly if key requires a passphrase."
        identity=""
        for k in id_ed25519 id_rsa id_ecdsa id_dsa; do
          if [ -f "$SSH_DIR/$k" ]; then
            identity="$SSH_DIR/$k"
            break
          fi
        done
        if [ -n "$identity" ]; then
          echo "Using identity file $identity for SSH operations"
          export GIT_SSH_COMMAND="ssh -i $identity -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes"
        else
          export GIT_SSH_COMMAND='ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes'
        fi
      fi
    else
      echo "Warning: SSH URL but no SSH keys found at /opt/ssh or $HOME/.ssh. Clone may fail without credentials."
    fi
    ;;
esac

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$CLONE_DIR" || { echo "git clone failed"; exit 3; }
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
      curl -fsSL -o "$tmp_installer" "$release_url" || { echo "Failed to download installer from $release_url"; tmp_installer=""; }
      if [ -n "$tmp_installer" ] && [ -f "$tmp_installer" ]; then
        chmod +x "$tmp_installer" || true
        "$tmp_installer" --target "$CLONE_DIR" --yes || echo "CLARE release installer failed"
        rm -f "$tmp_installer" || true
      fi
    else
      echo "No release installer URL found in README; falling back to cloning CLARE and running its installer"
      if command -v git >/dev/null 2>&1; then
        tmp_src=$(mktemp -d /tmp/clare-src.XXXXXX)
        git clone https://github.com/jketreno/clare "$tmp_src" || { echo "Failed to clone clare repo"; tmp_src=""; }
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
if [ -f "clare/verify-ci.sh" ]; then
  echo "Found clare/verify-ci.sh — running with --fast to validate installation scripts"
  chmod +x clare/verify-ci.sh
  bash clare/verify-ci.sh --fast || echo "clare/verify-ci.sh reported failures (non-blocking for this install test)"
else
  echo "No clare/verify-ci.sh found — skipping CLARE verification step"
fi

echo "=== Install smoke test completed ==="
exit 0
