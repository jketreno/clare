#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
TEMPLATES="${ROOT}/clare/templates/hooks"
SCRIPTS_TEMPLATES="${ROOT}/clare/templates/scripts"
SCRIPTS_TARGET="${ROOT}/clare/scripts"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required to merge CLARE2 hook configuration" >&2
  exit 1
}

merge_hooks() {
  local template=$1
  local target=$2
  local temporary
  temporary=$(mktemp)

  mkdir -p "$(dirname "$target")"
  if [[ -f "$target" ]]; then
    jq --slurpfile additions "$template" '
      reduce ($additions[0].hooks | keys[]) as $event (.;
        (.hooks[$event] // []) as $existing
        | [$existing[].hooks[]? | .command] as $commands
        | .hooks[$event] = (
            $existing +
            [
              $additions[0].hooks[$event][]
              | .hooks[0].command as $new_command
              | select($commands | index($new_command) | not)
            ]
          )
      )
    ' "$target" >"$temporary"
  else
    cp "$template" "$temporary"
  fi
  jq -e . "$temporary" >/dev/null
  chmod 0644 "$temporary"
  mv "$temporary" "$target"
}

mkdir -p "$SCRIPTS_TARGET"
cp "$SCRIPTS_TEMPLATES/clare2-capture-event.sh" "$SCRIPTS_TARGET/clare2-capture-event.sh"
chmod 0755 "$SCRIPTS_TARGET/clare2-capture-event.sh"

merge_hooks "$TEMPLATES/codex-hooks.json" "$ROOT/.codex/hooks.json"
merge_hooks "$TEMPLATES/claude-hooks.json" "$ROOT/.claude/settings.json"
mkdir -p "$ROOT/.github/hooks"
cp "$TEMPLATES/copilot-hooks.json" "$ROOT/.github/hooks/clare2-corpus.json"

echo "Installed CLARE2 hooks for Codex, Claude Code, and GitHub Copilot."
echo "Set CLARE2_CORPUS_ROOT or CLARE2_ROOT before starting an agent."
