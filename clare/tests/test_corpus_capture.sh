#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CAPTURE="$ROOT/clare/templates/scripts/clare2-capture-event.sh"
INSTALL="$ROOT/clare/templates/scripts/clare2-install-hooks.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

session_path() {
  printf '%s/sessions/testproject/%s/%s-%s.jsonl' \
    "$1" "$(date -u +%Y/%m/%d)" "$2" "$3"
}

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

test_claude_message_deltas_and_stop_deduplication() {
  local corpus="$TEMP/delta-corpus" session
  local common=(CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject CLARE2_CAPTURE_MAX_CHARS=40)
  printf '%s' '{"session_id":"delta","turn_id":"t1","message_id":"m1","index":0,"final":false,"delta":"token=abcdefghijkl"}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_message_delta
  printf '%s' '{"session_id":"delta","turn_id":"t1","message_id":"m2","index":0,"final":false,"delta":"Concurrent"}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_message_delta
  printf '%s' '{"session_id":"delta","turn_id":"t1","message_id":"m1","index":1,"final":true,"delta":"mnopqrstuv tail that truncates 012345678901234567890123456789"}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_message_delta
  printf '%s' '{"session_id":"delta","turn_id":"t1","message_id":"m2","index":1,"final":true,"delta":""}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_message_delta
  printf '%s' '{"session_id":"delta","last_assistant_message":"duplicate"}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_stop
  printf '%s' '{"session_id":"delta","last_assistant_message":"early duplicate"}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_stop
  printf '%s' '{"session_id":"delta","turn_id":"t2","message_id":"m3","index":0,"final":true,"delta":"After stop"}' \
    | env "${common[@]}" "$CAPTURE" claude assistant_message_delta
  session=$(session_path "$corpus" claude delta)
  jq -e -s '
    ([.[] | select(.type == "interaction" and .role == "assistant")] | length) == 3
    and ([.[] | select(.message_id == "m1")][0].content | contains("abcdefghijklmnopqrstuv") | not)
    and ([.[] | select(.message_id == "m1")][0].content | contains("[TRUNCATED]"))
    and ([.[] | select(.message_id == "m2")][0].content == "Concurrent")
    and ([.[] | select(.message_id == "m3")][0].content == "After stop")
    and ([.[] | select(.type == "turn_complete")] | length) == 2
  ' "$session" >/dev/null
}

test_interactive_dialog_normalization() {
  local corpus="$TEMP/dialog-corpus" session
  printf '%s' '{"session_id":"dialog","tool_use_id":"c1","tool_input":{"questions":[{"header":"Mode","question":"Pick one","options":[{"label":"Safe","description":"Recommended"}]}]}}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude interactive_prompt
  printf '%s' '{"session_id":"dialog","tool_use_id":"c1","tool_input":{"questions":[{"question":"Pick one"}]},"tool_response":{"answers":{"Mode":"Safe"}},"ignored":"do-not-store"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude interactive_response
  printf '%s' '{"session_id":"dialog","toolUseId":"x2","tool_input":{"questions":[{"question":"Password?","is_secret":true}]},"tool_response":{"answer":"hunter2"}}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" codex interactive_response
  printf '%s' '{"sessionId":"dialog","toolUseId":"g3","toolArgs":{"question":"Continue?"},"toolResult":{"textResultForLlm":"Yes"},"raw":"private-result"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" copilot interactive_response
  session=$(session_path "$corpus" claude dialog)
  jq -e -s '.[1].interaction_kind == "elicitation" and .[1].content == "Mode: Pick one\n- Safe: Recommended" and .[2].content == "Mode: Safe"' "$session" >/dev/null
  jq -e -s '.[1].content == "[REDACTED SENSITIVE RESPONSE]"' "$(session_path "$corpus" codex dialog)" >/dev/null
  jq -e -s '.[1].content == "Yes"' "$(session_path "$corpus" copilot dialog)" >/dev/null
  ! rg -q 'do-not-store|hunter2|private-result' "$corpus"
}

test_failures_subagents_and_cleanup() {
  local corpus="$TEMP/lifecycle-corpus" session pending
  printf '%s' '{"session_id":"life","tool_name":"read","tool_use_id":"ok","success":true}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude tool_result
  printf '%s' '{"session_id":"life","turn_id":"t","tool_name":"shell","error":"boom"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude tool_failure
  printf '%s' '{"session_id":"life","agent_id":"a1","last_assistant_message":"subagent answer"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude subagent_stop
  printf '%s' '{"session_id":"life","turn_id":"unfinished","message_id":"m","final":false,"delta":"partial"}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude assistant_message_delta
  session=$(session_path "$corpus" claude life)
  pending="${session}.pending"
  [[ -d "$pending" ]]
  printf '%s' '{"session_id":"life","turn_id":"unfinished"}' | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude turn_failure
  ! find "$pending" -maxdepth 1 -name 'claude-unfinished-*' | grep -q .
  printf '%s' '{"session_id":"life"}' | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" claude session_end
  jq -e -s '.[1].outcome == "completed" and .[1].tool_use_id == "ok" and .[2].outcome == "failure" and .[3].interaction_kind == "subagent" and .[4].event == "turn_failure" and .[5].event == "session_end"' "$session" >/dev/null
  [[ ! -d "$pending" ]]
}

test_copilot_transcript_fallback_is_opt_in() {
  local corpus="$TEMP/copilot-corpus" transcript="$TEMP/transcript.jsonl"
  printf '%s\n' '{"type":"assistant.message","data":{"content":"fallback response"}}' >"$transcript"
  jq -cn --arg path "$transcript" '{sessionId:"off",transcriptPath:$path}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject "$CAPTURE" copilot assistant_stop
  jq -e -s '.[1].type == "turn_complete"' "$(session_path "$corpus" copilot off)" >/dev/null
  jq -cn --arg path "$transcript" '{sessionId:"on",transcriptPath:$path}' \
    | CLARE2_CORPUS_ROOT="$corpus" CLARE2_PROJECT_ID=testproject CLARE2_COPILOT_TRANSCRIPT_FALLBACK=1 "$CAPTURE" copilot assistant_stop
  jq -e -s '.[1].type == "interaction" and .[1].content == "fallback response"' "$(session_path "$corpus" copilot on)" >/dev/null
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
    git -c user.email=test@example.com -c user.name=test add -A
    git -c user.email=test@example.com -c user.name=test commit -qm installed-hooks
    ./clare/scripts/clare2-install-hooks.sh >/dev/null
  )

  jq -e '.hooks.UserPromptSubmit | length == 1' \
    "$project/.codex/hooks.json" >/dev/null
  jq -e '(.hooks.PreCompact | length) == 1 and (.hooks.SubagentStop | length) == 1' \
    "$project/.codex/hooks.json" >/dev/null
  jq -e '.hooks.SessionStart | length == 2' \
    "$project/.codex/hooks.json" >/dev/null
  jq -e '.hooks.UserPromptSubmit | length == 1' \
    "$project/.claude/settings.json" >/dev/null
  jq -e '.permissions.allow == ["Bash(git status)"]' \
    "$project/.claude/settings.json" >/dev/null
  jq -e '(.hooks.MessageDisplay | length) == 1 and (.hooks.PostToolUseFailure | length) == 1 and (.hooks.SessionEnd | length) == 1' \
    "$project/.claude/settings.json" >/dev/null
  jq -e '.version == 1 and (.hooks.userPromptSubmitted | length == 1)' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
  jq -e '[.hooks.agentStop[].bash] | index("./custom.sh") != null' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
  jq -e '.hooks.agentStop | length == 2' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
  jq -e '(.hooks.postToolUseFailure | length) == 1 and (.hooks.sessionEnd | length) == 1 and (.hooks.subagentStop | length) == 1' \
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
test_claude_message_deltas_and_stop_deduplication
test_interactive_dialog_normalization
test_failures_subagents_and_cleanup
test_copilot_transcript_fallback_is_opt_in
test_hook_install_is_idempotent
test_hook_install_preserves_dirty_and_untracked_configs
echo "CLARE2 corpus capture tests passed"
