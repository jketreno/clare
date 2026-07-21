#!/usr/bin/env bash
set -uo pipefail
SOURCE="${1:-generic}"
EVENT="${2:-event}"
MAX_CONTENT_CHARS="${CLARE2_CAPTURE_MAX_CHARS:-12000}"
COPILOT_TRANSCRIPT_FALLBACK="${CLARE2_COPILOT_TRANSCRIPT_FALLBACK:-0}"
[[ "$MAX_CONTENT_CHARS" =~ ^[0-9]+$ ]] || MAX_CONTENT_CHARS=12000
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null || true)
[[ -n "$INPUT" ]] || INPUT="{}"
PAYLOAD=$(printf '%s' "$INPUT" | jq -c 'if type == "object" then . else {} end' 2>/dev/null) || PAYLOAD="{}"
if [[ "$EVENT" == "assistant_stop" && "$SOURCE" == "copilot" &&
  "$COPILOT_TRANSCRIPT_FALLBACK" == "1" ]]; then
  transcript_path=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)
  if [[ -n "$transcript_path" && -r "$transcript_path" ]]; then
    last_message=$(jq -sr '[.[] | select(.type == "assistant.message")] | last | .data.content // empty' \
      "$transcript_path" 2>/dev/null)
    if [[ -n "$last_message" ]]; then
      PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c --arg msg "$last_message" '. + {lastAssistantMessage: $msg}' 2>/dev/null) || true
    fi
  fi
fi
corpus_root() {
  [[ -n "${CLARE2_CORPUS_ROOT:-}" ]] && printf '%s' "$CLARE2_CORPUS_ROOT"
  [[ -z "${CLARE2_CORPUS_ROOT:-}" && -n "${CLARE2_ROOT:-}" ]] && printf '%s/corpus' "$CLARE2_ROOT"
}
session_id=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)
[[ -n "$session_id" ]] || session_id="${CLARE2_SESSION_ID:-manual-$$}"
safe_session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-' | cut -c1-128)
[[ -n "$safe_session_id" ]] || safe_session_id="manual-$$"
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
project="${CLARE2_PROJECT_ID:-}"
[[ -n "$project" ]] || project=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
if [[ -n "${CLARE2_SESSION_FILE:-}" ]]; then
  session_file="$CLARE2_SESSION_FILE"
else
  root=$(corpus_root)
  [[ -n "$root" ]] || exit 0
  day=$(date -u +%Y/%m/%d)
  session_file="${root}/sessions/${project}/${day}/${SOURCE}-${safe_session_id}.jsonl"
fi
meta=$(jq -cn --arg session_id "$safe_session_id" --arg project "$project" --arg source "$SOURCE" --arg started_at "$timestamp" '{type:"session_meta",session_id:$session_id,project:$project,source:$source,started_at:$started_at}')
append_record() {
  local next_record=$1
  mkdir -p "$(dirname "$session_file")" 2>/dev/null || return 0
  [[ -s "$session_file" ]] || printf '%s\n' "$meta" >>"$session_file"
  printf '%s\n' "$next_record" >>"$session_file"
}
append_locked() {
  local next_record=$1
  mkdir -p "$(dirname "$session_file")" 2>/dev/null || return 0
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      append_record "$next_record"
    ) 9>"${session_file}.lock"
  else
    append_record "$next_record"
  fi
}
protected_json() {
  jq -Rs --argjson max_content_chars "$MAX_CONTENT_CHARS" '
    def redact:
      gsub("(?s)```.*?```"; "[REDACTED CODE BLOCK]")
      | gsub("(?is)-----BEGIN [^-\\n]+-----.*?-----END [^-\\n]+-----";
          "[REDACTED PRIVATE KEY]")
      | gsub("(?i)(?<prefix>authorization[\" ]*[=:][\" ]*)[^\\r\\n\"]+";
          "\(.prefix)[REDACTED]")
      | gsub("(?i)(?<prefix>bearer[ ]+)[A-Za-z0-9._~+/-]+";
          "\(.prefix)[REDACTED]")
      | gsub("(?i)(?<label>aws_access_key_id|aws_secret_access_key|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key|secret|token|password)(?<separator>[\" ]*[=:][\" ]*)[^ ,;\"\\r\\n]+";
          "\(.label)\(.separator)[REDACTED]")
      | gsub("(?i)(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,})";
          "[REDACTED TOKEN]");
    if $max_content_chars == 0 then ""
    else redact
      | if length > $max_content_chars then
          .[0:$max_content_chars] + "\n[TRUNCATED]"
        else . end
    end
  '
}
safe_key() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-128; }
pending_dir="${session_file}.pending"
display_marker="${pending_dir}/${SOURCE}.display-captured"
stop_fallback="${pending_dir}/${SOURCE}.stop-fallback.json"
capture_assistant_delta() {
  [[ "$MAX_CONTENT_CHARS" != "0" ]] || return 0
  local turn_id message_id index final delta safe_turn safe_message pending marker
  turn_id=$(printf '%s' "$PAYLOAD" | jq -r '.turn_id // .turnId // empty')
  message_id=$(printf '%s' "$PAYLOAD" | jq -r '.message_id // .messageId // empty')
  index=$(printf '%s' "$PAYLOAD" | jq -r '.index // 0')
  final=$(printf '%s' "$PAYLOAD" | jq -r '.final // false')
  delta=$(printf '%s' "$PAYLOAD" | jq -r '.delta // ""')
  safe_turn=$(safe_key "$turn_id")
  safe_message=$(safe_key "$message_id")
  [[ -n "$safe_turn" && -n "$safe_message" ]] || return 0
  mkdir -p "$pending_dir" 2>/dev/null || return 0
  chmod 0700 "$pending_dir"
  pending="${pending_dir}/${SOURCE}-${safe_turn}-${safe_message}.json"
  marker="$display_marker"
  capture_delta_locked() {
    local previous combined content_json next_record
    previous=""
    if [[ "$index" != "0" && -s "$pending" ]]; then
      previous=$(jq -r '.content // ""' "$pending" 2>/dev/null || true)
    fi
    combined="${previous}${delta}"
    combined=$(printf '%s' "$combined" | jq -Rs --argjson max "$MAX_CONTENT_CHARS" 'if length > $max then .[0:$max] + "\n[TRUNCATED]" else . end') || return 0
    jq -cn --argjson content "$combined" '{content:$content}' >"${pending}.tmp"
    chmod 0600 "${pending}.tmp"
    mv "${pending}.tmp" "$pending"
    [[ "$final" == "true" ]] || return 0
    content_json=$(printf '%s' "$combined" | jq -r '.' | protected_json) || return 0
    if [[ -n "$(printf '%s' "$content_json" | jq -r '.')" ]]; then
      next_record=$(jq -cn --arg source "$SOURCE" --arg content "$(printf '%s' "$content_json" | jq -r '.')" \
        --arg session_id "$session_id" --arg turn_id "$turn_id" --arg message_id "$message_id" --arg ts "$timestamp" --arg project "$project" \
        '{type:"interaction",source:$source,role:"assistant",content:$content,
          session_id:$session_id,turn_id:$turn_id,message_id:$message_id,ts:$ts,project:$project}')
      append_locked "$next_record"
      if [[ -s "$stop_fallback" ]]; then
        rm -f "$stop_fallback"
        next_record=$(jq -cn --arg source "$SOURCE" --arg session_id "$session_id" --arg turn_id "$turn_id" --arg ts "$timestamp" --arg project "$project" \
          '{type:"turn_complete",source:$source,session_id:$session_id,
            turn_id:$turn_id,ts:$ts,project:$project}')
        append_locked "$next_record"
      else
        : >"$marker"
        chmod 0600 "$marker"
      fi
    fi
    rm -f "$pending"
  }
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 8
      capture_delta_locked
    ) 8>"${pending}.lock"
  else
    capture_delta_locked
  fi
}
[[ "$EVENT" != "assistant_message_delta" ]] || {
  capture_assistant_delta
  exit 0
}
turn_id=$(printf '%s' "$PAYLOAD" | jq -r '.turn_id // .turnId // empty')
safe_turn=$(safe_key "$turn_id")
claude_display_captured=0
claude_defer_stop=0
if [[ "$EVENT" == "assistant_stop" && "$SOURCE" == "claude" ]]; then
  if [[ -f "$display_marker" ]]; then
    EVENT="turn_complete"
    claude_display_captured=1
  else claude_defer_stop=1; fi
fi
record=$(printf '%s' "$PAYLOAD" | jq -c --arg source "$SOURCE" --arg event "$EVENT" --arg ts "$timestamp" \
  --arg project "$project" --argjson max_content_chars "$MAX_CONTENT_CHARS" '
  def redact:
    gsub("(?s)```.*?```"; "[REDACTED CODE BLOCK]")
    | gsub("(?is)-----BEGIN [^-\\n]+-----.*?-----END [^-\\n]+-----";
        "[REDACTED PRIVATE KEY]")
    | gsub("(?i)(?<prefix>authorization[\" ]*[=:][\" ]*)[^\\r\\n\"]+";
        "\(.prefix)[REDACTED]")
    | gsub("(?i)(?<prefix>bearer[ ]+)[A-Za-z0-9._~+/-]+";
        "\(.prefix)[REDACTED]")
    | gsub("(?i)(?<label>aws_access_key_id|aws_secret_access_key|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key|secret|token|password)(?<separator>[\" ]*[=:][\" ]*)[^ ,;\"\\r\\n]+";
        "\(.label)\(.separator)[REDACTED]")
    | gsub("(?i)(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,})";
        "[REDACTED TOKEN]");
  def bounded:
    if $max_content_chars == 0 then ""
    elif length > $max_content_chars then
      .[0:$max_content_chars] + "\n[TRUNCATED]"
    else .
    end;
  def protected: tostring | redact | bounded;
  def session: (.session_id // .sessionId // null);
  def turn: (.turn_id // .turnId // null);
  if $event == "user_prompt" then
    {
      type: "interaction", source: $source, role: "user",
      content: ((.prompt // "") | protected),
      session_id: session, turn_id: turn, ts: $ts, project: $project
    } | select(.content != "")
  elif $event == "interactive_prompt" then
    (.tool_input // .toolArgs // {}) as $input
    | ($input.questions // (if $input.question then [$input] else [] end)) as $questions
    | ($questions | map(
        ([.header, .question] | map(select(type == "string" and length > 0)) | join(": "))
        + (if (.options // [] | length) > 0 then
            "\n" + ([.options[] | "- " + (.label // "")
              + (if (.description // "") == "" then "" else ": " + .description end)] | join("\n"))
          else "" end)
      ) | join("\n\n")) as $message
    | {
        type: "interaction", source: $source, role: "assistant",
        content: ($message | protected), interaction_kind: "elicitation",
        tool_use_id: (.tool_use_id // .toolUseId // null),
        session_id: session, turn_id: turn, ts: $ts, project: $project
      } | select(.content != "")
  elif $event == "interactive_response" then
    (.tool_input // .toolArgs // {}) as $input
    | ([$input.questions[]? | select(.is_secret == true)] | length > 0) as $sensitive
    | (.tool_response.answers // .toolResponse.answers // .tool_response.answer
      // .toolResponse.answer // .tool_result.text_result_for_llm
      // .toolResult.textResultForLlm
      // (if (.tool_response | type) == "string" then .tool_response else null end)
      // (if (.toolResponse | type) == "string" then .toolResponse else null end)) as $answer
    | (if $sensitive then "[REDACTED SENSITIVE RESPONSE]"
       elif ($answer | type) == "object" then
         [$answer | to_entries[] | "\(.key): \(.value | tostring)"] | join("\n")
       elif $answer == null then "" else ($answer | tostring) end) as $message
    | {
        type: "interaction", source: $source, role: "user",
        content: ($message | protected), interaction_kind: "elicitation",
        tool_use_id: (.tool_use_id // .toolUseId // null),
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
          content: ($message | protected),
          message_id: (.message_id // .messageId // null), session_id: session,
          turn_id: turn, ts: $ts, project: $project
        }
      end
  elif $event == "subagent_stop" then
    (.last_assistant_message // .lastAssistantMessage // null) as $message
    | if $message == null then
        {type: "session_event", source: $source, event: $event,
          agent_id: (.agent_id // .agentId // null), session_id: session,
          turn_id: turn, ts: $ts, project: $project}
      else
        {type: "interaction", source: $source, role: "assistant",
          content: ($message | protected), interaction_kind: "subagent",
          agent_id: (.agent_id // .agentId // null), session_id: session,
          turn_id: turn, ts: $ts, project: $project}
      end
  elif $event == "turn_complete" then
    {
      type: "turn_complete", source: $source, session_id: session,
      turn_id: turn, ts: $ts, project: $project
    }
  elif $event == "tool_result" or $event == "tool_failure" then
    {
      type: "tool_result", source: $source,
      tool: (.tool_name // .toolName // "unknown"),
      outcome: (if $event == "tool_failure" or (.error? != null)
        or .success? == false or .tool_response.success? == false
        or .toolResult.resultType? == "failure" then "failure" else "completed" end),
      tool_use_id: (.tool_use_id // .toolUseId // null),
      agent_id: (.agent_id // .agentId // null),
      session_id: session, turn_id: turn, ts: $ts, project: $project
    }
  elif $event == "correction" then
    {
      type: "correction", source: $source,
      problem: ((.problem // "") | protected),
      preferred: ((.preferred // "") | protected),
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
if [[ "$claude_defer_stop" == "1" ]]; then
  mkdir -p "$pending_dir" 2>/dev/null || exit 0
  chmod 0700 "$pending_dir"
  printf '%s\n' "$record" >"${stop_fallback}.tmp"
  chmod 0600 "${stop_fallback}.tmp"
  mv "${stop_fallback}.tmp" "$stop_fallback"
  exit 0
fi
if [[ "$SOURCE" == "claude" && ("$EVENT" == "user_prompt" || "$EVENT" == "session_end") &&
  -s "$stop_fallback" ]]; then
  append_locked "$(cat "$stop_fallback")"
  rm -f "$stop_fallback"
fi
append_locked "$record"
[[ "$claude_display_captured" == "1" ]] && rm -f "$display_marker"
if [[ "$EVENT" == "session_end" && -d "$pending_dir" ]]; then
  find "$pending_dir" -maxdepth 1 -type f -name "${SOURCE}-*" -delete 2>/dev/null || true
  rmdir "$pending_dir" 2>/dev/null || true
elif [[ "$EVENT" == "turn_failure" && -n "$safe_turn" && -d "$pending_dir" ]]; then
  find "$pending_dir" -maxdepth 1 -type f -name "${SOURCE}-${safe_turn}-*" -delete 2>/dev/null || true
  rm -f "$display_marker"
fi
exit 0
