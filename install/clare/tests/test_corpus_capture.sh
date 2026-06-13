#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CAPTURE="$ROOT/clare/templates/scripts/clare2-capture-event.sh"
INSTALL="$ROOT/clare/templates/scripts/clare2-install-hooks.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

test_capture_records_and_redacts() {
  local corpus="$TEMP/corpus"
  CLARE2_CORPUS_ROOT="$corpus" \
    printf '%s' '{"session_id":"s1","turn_id":"t1","prompt":"token=secret"}' \
    | CLARE2_CORPUS_ROOT="$corpus" "$CAPTURE" codex user_prompt

  local session="$corpus/sessions/$(date -u +%Y/%m/%d)/codex-s1.jsonl"
  jq -e -s '
    length == 2
    and .[0].type == "session_meta"
    and .[1].type == "interaction"
    and .[1].content == "token=[REDACTED]"
  ' "$session" >/dev/null
}

test_hook_install_is_idempotent() {
  local project="$TEMP/project"
  mkdir -p "$project/clare/templates" "$project/clare/scripts"
  cp -R "$ROOT/clare/templates/hooks" "$project/clare/templates/hooks"
  cp -R "$ROOT/clare/templates/scripts" "$project/clare/templates/scripts"
  cp "$INSTALL" "$project/clare/scripts/clare2-install-hooks.sh"
  git -C "$project" init -q
  mkdir -p "$project/.codex" "$project/.claude" "$project/.github/hooks"
  printf '%s\n' \
    '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
    >"$project/.codex/hooks.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(git status)"]}}' \
    >"$project/.claude/settings.json"
  printf '%s\n' \
    '{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"./custom.sh","cwd":".","timeoutSec":5}]}}' \
    >"$project/.github/hooks/clare2-corpus.json"

  (
    cd "$project"
    ./clare/scripts/clare2-install-hooks.sh >/dev/null
    ./clare/scripts/clare2-install-hooks.sh >/dev/null
  )

  jq -e '.hooks.UserPromptSubmit | length == 1' \
    "$project/.codex/hooks.json" >/dev/null
  jq -e '.hooks.SessionStart | length == 2' \
    "$project/.codex/hooks.json" >/dev/null
  jq -e '.hooks.UserPromptSubmit | length == 1' \
    "$project/.claude/settings.json" >/dev/null
  jq -e '.permissions.allow == ["Bash(git status)"]' \
    "$project/.claude/settings.json" >/dev/null
  jq -e '.version == 1 and (.hooks.userPromptSubmitted | length == 1)' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
  jq -e '[.hooks.agentStop[].bash] | index("./custom.sh") != null' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
  jq -e '.hooks.agentStop | length == 2' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null

  [[ -x "$project/clare/scripts/clare2-capture-event.sh" ]]
}

test_capture_records_and_redacts
test_hook_install_is_idempotent
echo "CLARE2 corpus capture tests passed"
