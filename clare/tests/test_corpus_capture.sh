#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CAPTURE="$ROOT/clare/templates/scripts/clare2-capture-event.sh"
INSTALL="$ROOT/clare/templates/scripts/clare2-install-hooks.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

test_capture_records_and_redacts() {
  local corpus="$TEMP/corpus"
  printf '%s' '{"session_id":"s1","turn_id":"t1","prompt":"token=secret"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID="testproject" \
      "$CAPTURE" codex user_prompt

  local session="$corpus/sessions/testproject/$(date -u +%Y/%m/%d)/codex-s1.jsonl"
  jq -e -s '
    length == 2
    and .[0].type == "session_meta"
    and .[1].type == "interaction"
    and .[1].content == "token=[REDACTED]"
  ' "$session" >/dev/null
}

test_capture_redacts_common_secret_forms_and_bounds_content() {
  local corpus="$TEMP/sensitive-corpus"
  local private_key prompt
  private_key=$'-----BEGIN PRIVATE KEY-----\nabc123\n-----END PRIVATE KEY-----'
  prompt=$'Authorization: Basic dXNlcjpwYXNz\n'
  prompt+=$'AWS_SECRET_ACCESS_KEY=abc123\n'
  prompt+=$'client_secret: hunter2\n'
  prompt+=$'github_pat_abcdefghijklmnopqrstuvwxyz\n'
  prompt+="$private_key"
  prompt+=$'\n```python\nprint("complete source file")\n```\n'
  prompt+=$'0123456789abcdefghijklmnopqrstuvwxyz'
  jq -cn \
    --arg prompt "$prompt" \
    '{session_id:"sensitive",prompt:$prompt}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID="testproject" \
      CLARE2_CAPTURE_MAX_CHARS=220 "$CAPTURE" codex user_prompt

  local session="$corpus/sessions/testproject/$(date -u +%Y/%m/%d)/codex-sensitive.jsonl"
  jq -e -s '
    .[1].content
    | contains("Authorization: Basic dXNlcjpwYXNz") | not
  ' "$session" >/dev/null
  jq -e -s '.[1].content | contains("abc123") | not' "$session" >/dev/null
  jq -e -s '.[1].content | contains("hunter2") | not' "$session" >/dev/null
  jq -e -s '
    .[1].content
    | contains("github_pat_abcdefghijklmnopqrstuvwxyz") | not
  ' "$session" >/dev/null
  jq -e -s '
    .[1].content
    | contains("BEGIN PRIVATE KEY") | not
  ' "$session" >/dev/null
  jq -e -s '
    .[1].content
    | contains("complete source file") | not
  ' "$session" >/dev/null
  jq -e -s '.[1].content | length <= 232' "$session" >/dev/null
}

test_zero_content_limit_disables_interaction_capture() {
  local corpus="$TEMP/disabled-corpus"
  printf '%s' '{"session_id":"disabled","prompt":"do not persist"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID="testproject" \
      CLARE2_CAPTURE_MAX_CHARS=0 "$CAPTURE" codex user_prompt

  [[ ! -e "$corpus" ]]
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
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qm hooks

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

test_hook_install_preserves_dirty_and_untracked_configs() {
  local project="$TEMP/dirty-hooks-project"
  mkdir -p "$project/clare/templates" "$project/clare/scripts"
  cp -R "$ROOT/clare/templates/hooks" "$project/clare/templates/hooks"
  cp -R "$ROOT/clare/templates/scripts" "$project/clare/templates/scripts"
  cp "$INSTALL" "$project/clare/scripts/clare2-install-hooks.sh"
  git -C "$project" init -q
  mkdir -p "$project/.codex" "$project/.claude"
  printf '%s\n' '{"hooks":{}}' >"$project/.codex/hooks.json"
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qm initial

  printf '%s\n' '{"hooks":{},"local":"dirty"}' >"$project/.codex/hooks.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(custom)"]}}' \
    >"$project/.claude/settings.json"
  local codex_before claude_before
  codex_before="$(cat "$project/.codex/hooks.json")"
  claude_before="$(cat "$project/.claude/settings.json")"

  (
    cd "$project"
    ./clare/scripts/clare2-install-hooks.sh >/dev/null
  )

  [[ "$codex_before" == "$(cat "$project/.codex/hooks.json")" ]]
  [[ "$claude_before" == "$(cat "$project/.claude/settings.json")" ]]
  jq -e '.hooks.sessionStart | length == 1' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
}

test_capture_records_and_redacts
test_capture_redacts_common_secret_forms_and_bounds_content
test_zero_content_limit_disables_interaction_capture
test_hook_install_is_idempotent
test_hook_install_preserves_dirty_and_untracked_configs
echo "CLARE2 corpus capture tests passed"
