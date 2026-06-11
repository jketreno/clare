# Qwen Automatic Corpus Capture Plan

## Objective

Add opt-in corpus capture to the CLARE2 OpenAI-compatible policy proxy so
requests served by the local Qwen3.5 model contribute normalized interaction
evidence even when the calling agent has no lifecycle-hook integration.

This is a future implementation plan. It does not change proxy behavior yet.

## Design Principles

- Agent hooks remain the primary source for corrections, tool outcomes, and
  workflow context.
- Proxy capture supplements hooks with complete local-model request/response
  coverage.
- Capture is explicit, authenticated, project-scoped, bounded, and fail-open.
- Internal CLARE2 model calls never re-enter the corpus.
- Prompts and responses are sensitive local data and are never audit-logged.
- Hidden reasoning, credentials, binary content, and embeddings are excluded.

## Request Contract

Accept these headers only after normal proxy authentication:

```text
X-CLARE-Capture: enabled
X-CLARE-Session-ID: <opaque session id>
X-CLARE-Turn-ID: <opaque turn id>
X-CLARE-Project-ID: <configured project key or canonical repository id>
X-CLARE-Source: <agent identifier>
X-CLARE-Internal: <pipeline operation>
```

Rules:

1. Capture requires `X-CLARE-Capture: enabled`.
2. Session and project identities are validated and length-limited.
3. Project identity is canonicalized through `CLARE2_PROJECT_MAP`.
4. `X-CLARE-Internal` always disables capture.
5. Requests without valid capture context continue normally without capture.
6. Clients cannot provide corpus paths or filenames.

## Capture Schema

Write normalized records into:

```text
/corpus/sessions/YYYY/MM/DD/qwen-<session-id>.jsonl
```

Record types:

```json
{"type":"session_meta","session_id":"...","project":"...","source":"...","started_at":"..."}
{"type":"interaction","role":"user","content":"...","turn_id":"...","model":"...","adapter_id":"...","ts":"..."}
{"type":"interaction","role":"assistant","content":"...","turn_id":"...","model":"...","adapter_id":"...","ts":"..."}
{"type":"model_result","turn_id":"...","status":200,"prompt_tokens":0,"completion_tokens":0,"latency_ms":0,"ts":"..."}
```

Do not store route bearer tokens or opaque route IDs. Store the resolved
immutable adapter ID and canonical project ID.

## Request Normalization

Support:

- `/v1/chat/completions`
- `/v1/completions`

Exclude:

- `/v1/embeddings`
- `/v1/models`
- health and operator APIs
- adapter management calls
- distillation, summarization, evaluation, smoke, and lifecycle requests

For chat requests:

- preserve role and text content
- flatten text-only content arrays
- replace image, audio, file, and unknown parts with typed placeholders
- exclude tool schemas and tool-call arguments from the corpus
- cap content by configured bytes and message count

For completion requests:

- normalize the prompt as a user interaction
- reject capture for unsupported binary or token-array forms

## Response Capture

### Non-streaming

Parse successful JSON responses and record assistant text plus token usage.
For unsuccessful responses, write only `model_result` metadata.

### Streaming

Forward chunks without waiting for completion. In parallel:

1. Parse Server-Sent Events incrementally.
2. Accumulate only assistant text deltas up to a configured maximum.
3. Record usage from the final chunk when available.
4. Commit the assistant record only after a normal stream terminator.
5. Mark disconnected or malformed streams as incomplete without storing
   partial assistant content by default.

The capture path must not materially delay first-token or chunk delivery.

## Redaction And Limits

Create a dedicated capture module, separate from proxy routing.

Required controls:

- configurable maximum prompt and response bytes
- maximum messages and per-message length
- obvious bearer token, API key, password, cookie, and private-key redaction
- configurable project-specific redaction patterns
- UTF-8 normalization and control-character removal
- no raw request headers
- no environment values
- no tool arguments or tool output
- no hidden reasoning fields

Redaction failure disables capture for that request but does not fail inference.

## Atomicity And Concurrency

- Serialize appends per session file.
- Write one compact JSON object per line.
- Create `session_meta` exactly once.
- Use temporary files, `fsync`, and atomic rename for mutable indexes.
- Do not hold the inference response open while waiting for corpus I/O.
- Use a bounded in-process queue and one writer worker.
- On queue saturation, increment a dropped-event metric and continue inference.

## Deduplication

Agent hooks and proxy capture may observe the same turn. Use:

```text
project + session_id + turn_id + role
```

as the logical event key. Distillation should prefer richer hook records when
both sources exist and retain proxy records only for missing roles.

Persist a bounded deduplication index or perform deterministic deduplication
when loading a session. Do not rewrite append-only raw session files.

## Internal Call Exclusion

Update every internal Qwen caller to send an internal marker:

- `distillation`
- `weekly_summary`
- `monthly_summary`
- `quarterly_summary`
- `evaluation`
- `smoke`
- `rollback_smoke`

The proxy must also recognize requests originating from the private control
network as internal defense in depth. Header marking remains mandatory for
testability and audit clarity.

## Configuration

Add environment settings:

```dotenv
CLARE2_PROXY_CAPTURE_ENABLED=false
CLARE2_CAPTURE_MAX_PROMPT_BYTES=131072
CLARE2_CAPTURE_MAX_RESPONSE_BYTES=131072
CLARE2_CAPTURE_QUEUE_SIZE=1024
CLARE2_CAPTURE_INCOMPLETE_STREAMS=false
CLARE2_CAPTURE_RETENTION_DAYS=90
```

Default proxy capture to disabled. Agent hook capture remains separately
configured through the CLARE-installed integration.

## Metrics And Audit

Metrics:

- capture requests accepted, skipped, redacted, and dropped
- records by source, role, and immutable adapter ID
- queue depth and writer latency
- content bytes before and after redaction
- incomplete streams
- deduplicated records

Audit logs may contain project ID, session ID, turn ID, source, adapter ID,
capture outcome, and sizes. They must never contain prompt or response text.

## Tests

Unit tests:

- consent and header validation
- project canonicalization
- internal-call exclusion
- redaction and size limits
- chat and completion normalization
- unsupported multimodal placeholders
- session path containment
- concurrent append atomicity
- deduplication preference
- queue saturation behavior

Integration tests:

- non-streaming request and response capture
- streaming forwarding with assembled assistant output
- client disconnect and malformed SSE behavior
- base and adapter-routed requests
- invalid capture headers still permit inference
- internal distillation never enters the corpus
- agent-hook and proxy records deduplicate into one turn

Security tests:

- path traversal in IDs
- credential patterns
- forged project IDs
- oversized bodies and responses
- attempts to capture embeddings or management endpoints
- prompt text absent from structured audit logs

## Rollout

1. Implement behind the disabled feature flag.
2. Run unit and fake-vLLM integration tests.
3. Enable only for a dedicated local test project.
4. Compare hook-only, proxy-only, and combined session quality.
5. Inspect redaction and deduplication results manually.
6. Run one DGX corpus cycle without training.
7. Enable training only after corpus review.
8. Document retention, deletion, and operator disable procedures.

## Acceptance Criteria

- Inference behavior is unchanged when capture is disabled.
- Capture failures never fail or delay inference beyond the latency budget.
- Internal pipeline requests produce zero raw session records.
- Streaming responses remain streaming.
- No credentials or hidden reasoning appear in fixtures or captured output.
- Captured turns are canonical, bounded, valid JSONL, and distillable.
- Hook and proxy observations do not double-count a turn.
