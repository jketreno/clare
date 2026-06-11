#!/usr/bin/env bash
set -uo pipefail

SOURCE="${1:-generic}"
EVENT="${2:-event}"

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null || true)
[[ -n "$INPUT" ]] || INPUT="{}"
PAYLOAD=$(printf '%s' "$INPUT" | jq -c 'if type == "object" then . else {} end' 2>/dev/null) \
  || PAYLOAD="{}"

corpus_root() {
  if [[ -n "${CLARE2_CORPUS_ROOT:-}" ]]; then
    printf '%s' "$CLARE2_CORPUS_ROOT"
  elif [[ -n "${CLARE2_ROOT:-}" ]]; then
    printf '%s/corpus' "$CLARE2_ROOT"
  fi
}

session_id=$(printf '%s' "$PAYLOAD" | jq -r \
  '.session_id // .sessionId // empty' 2>/dev/null)
[[ -n "$session_id" ]] || session_id="${CLARE2_SESSION_ID:-manual-$$}"
safe_session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-' | cut -c1-128)
[[ -n "$safe_session_id" ]] || safe_session_id="manual-$$"

if [[ -n "${CLARE2_SESSION_FILE:-}" ]]; then
  session_file="$CLARE2_SESSION_FILE"
else
  root=$(corpus_root)
  [[ -n "$root" ]] || exit 0
  day=$(date -u +%Y/%m/%d)
  session_file="${root}/sessions/${day}/${SOURCE}-${safe_session_id}.jsonl"
fi

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
project="${CLARE2_PROJECT_ID:-}"
if [[ -z "$project" ]]; then
  project=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
fi

record=$(printf '%s' "$PAYLOAD" | jq -c \
  --arg source "$SOURCE" \
  --arg event "$EVENT" \
  --arg ts "$timestamp" \
  --arg project "$project" '
  def redact:
    gsub("(?i)(?<prefix>bearer[ ]+)[A-Za-z0-9._~+/-]+";
        "\(.prefix)[REDACTED]")
    | gsub("(?i)(?<label>api[_-]?key|token|password)(?<separator>[\" =:]+)[^ ,\"\n]+";
        "\(.label)\(.separator)[REDACTED]");
  def session: (.session_id // .sessionId // null);
  def turn: (.turn_id // .turnId // null);
  if $event == "user_prompt" then
    {
      type: "interaction", source: $source, role: "user",
      content: ((.prompt // "") | tostring | redact),
      session_id: session, turn_id: turn, ts: $ts, project: $project
    } | select(.content != "")
  elif $event == "assistant_stop" then
    (.last_assistant_message // .lastAssistantMessage // null) as $message
    | if $message == null then
        {
          type: "turn_complete", source: $source, session_id: session,
          turn_id: turn, ts: $ts, project: $project
        }
      else
        {
          type: "interaction", source: $source, role: "assistant",
          content: ($message | tostring | redact), session_id: session,
          turn_id: turn, ts: $ts, project: $project
        }
      end
  elif $event == "tool_result" then
    {
      type: "tool_result", source: $source,
      tool: (.tool_name // .toolName // "unknown"),
      outcome: (if (.error? != null) then "failure" else "completed" end),
      session_id: session, turn_id: turn, ts: $ts, project: $project
    }
  elif $event == "correction" then
    {
      type: "correction", source: $source,
      problem: ((.problem // "") | tostring | redact),
      preferred: ((.preferred // "") | tostring | redact),
      session_id: session, turn_id: turn, ts: $ts, project: $project
    } | select(.problem != "" and .preferred != "")
  else
    {
      type: "session_event", source: $source, event: $event,
      session_id: session, turn_id: turn, ts: $ts, project: $project
    }
  end
  ' 2>/dev/null) || exit 0
[[ -n "$record" ]] || exit 0

mkdir -p "$(dirname "$session_file")" 2>/dev/null || exit 0
meta=$(jq -cn \
  --arg session_id "$safe_session_id" \
  --arg project "$project" \
  --arg source "$SOURCE" \
  --arg started_at "$timestamp" \
  '{type:"session_meta",session_id:$session_id,project:$project,
    source:$source,started_at:$started_at}')

append_records() {
  if [[ ! -s "$session_file" ]]; then
    printf '%s\n' "$meta" >>"$session_file"
  fi
  printf '%s\n' "$record" >>"$session_file"
}

if command -v flock >/dev/null 2>&1; then
  (
    flock -x 9
    append_records
  ) 9>"${session_file}.lock"
else
  append_records
fi

exit 0
