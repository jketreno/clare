# CLARE₂ Setup and Operations HOWTO

This guide uses two sibling repositories:

```text
/home/you/docker/clare      # CLARE framework and agent configuration
/home/you/docker/ai-vllm    # CLARE₂ runtime and setup-clare2.sh
```

Set each variable to its repository checkout:

```bash
export CLARE_ROOT=/path/to/clare
export CLARE2_ROOT=/path/to/ai-vllm
```

CLARE₂ is the runtime implemented in `ai-vllm`; it is not a separate
`clare2/` repository.

## 1. Prerequisites
- Docker Compose and NVIDIA Container Toolkit
- A supported NVIDIA GPU with enough memory for Qwen3.5
- Hugging Face access to serving and training checkpoints
- `openssl`, `curl`, `jq`, and `flock`
- Local Qwen3.5 serving through the included vLLM container

Distillation and summarization use the same local Qwen3.5 vLLM service.

## 2. Run Automated Setup
The setup script performs host configuration in Docker:

- creates `.env` and local secrets
- resolves immutable model revisions
- downloads both Qwen snapshots into `models/huggingface/`
- computes the training config and tokenizer fingerprints
- builds CLARE₂ images and creates the one-shot trainer
- starts a private MLflow tracking server with local persistent storage
- starts the core stack and validates its health
- installs project-local Codex capture hooks

```bash
HF_TOKEN='<Hugging Face token>' \
CLARE2_PROJECT_MAP='{"clare":"github:jketreno/clare"}' \
CLARE2_PROJECT_ID='github:jketreno/clare' \
"$CLARE2_ROOT/setup-clare2.sh" --capture-project "$CLARE_ROOT"
```

Without `HF_TOKEN`, an interactive terminal prompts for it. Existing secrets
and downloaded snapshots are reused. Use `--no-start` to prepare without
starting services.

The model cache is a host bind mount shared by vLLM and the trainer:

```text
$CLARE2_ROOT/models/huggingface -> /root/.cache/huggingface
```

Override it with `CLARE2_MODEL_CACHE=/absolute/path`. The script writes the
absolute path to `.env`. `vllm-engine` still has no host-published port.

### Resulting Services and Storage

- `127.0.0.1:5000`: MLflow training runs and adapter artifacts
- `127.0.0.1:8000`: policy proxy and operator API
- `127.0.0.1:8002`: Temper MCP tools
- private `vllm-engine`: base model and runtime LoRA management
- `corpus/`: sessions, episodes, summaries, themes, and training data
- `models/adapters/registry.json`: adapter source of truth

## 3. Connect Agents
Register the streamable HTTP MCP server:

```text
http://127.0.0.1:8002/mcp
```

Tools:

- `clare_temper_route(project, task_kind, capabilities)`
- `clare_temper_status(route_id)`
- `clare_temper_list(project)`

Obtain one route per agent session and send it on inference requests:

```bash
PROXY_TOKEN=$(<"$CLARE2_ROOT/secrets/clare2_proxy_token")
curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Authorization: Bearer $PROXY_TOKEN" \
  -H "X-CLARE-Route-ID: <route-id>" \
  -H "Content-Type: application/json" \
  -d '{"model":"ignored","messages":[{"role":"user","content":"Review this."}]}'
```

The proxy overwrites `model`; no route means the base model.

## 4. Generate Raw Session Corpus

### A. Launch an agent with capture enabled

There is no cross-agent standard log location. Codex currently stores private
session transcripts under `$CODEX_HOME/sessions` (normally
`~/.codex/sessions`), but that transcript format is explicitly not a stable
hook interface. Do not scrape it. Use the documented
[Codex lifecycle hooks](https://developers.openai.com/codex/hooks) instead.

The supported CLARE₂ ingestion location is:

```text
$CLARE2_ROOT/corpus/sessions/YYYY/MM/DD/<session-id>.jsonl
```

The setup command's `--capture-project` option installs
`<project>/.codex/hooks.json`. Those hooks normalize `UserPromptSubmit` and
`Stop` events into `interaction` records. Launch Codex through the wrapper so
the hooks and child commands share one `CLARE2_SESSION_FILE`:

```bash
cd "$CLARE2_ROOT"
./clare2/scripts/clare2-agent.sh codex "$CLARE_ROOT"
```

In Codex, run `/hooks` once after installation or changes and trust the
project-local hook definitions. Capture starts on the next wrapped session.
The resulting JSONL contains user prompts and final assistant messages, so
treat `corpus/` as sensitive data and keep secrets out of prompts.

### B. CLARE verification events
```bash
cd "$CLARE_ROOT"
export CORPUS_ROOT="$CLARE2_ROOT/corpus"
eval "$("$CLARE2_ROOT/clare2/scripts/clare2-session-start.sh")"
./clare/verify-ci.sh
```

This records `session_meta`, `ci_result`, `correction`, and `file_tier` objects
under `corpus/sessions/YYYY/MM/DD/<uuid>.jsonl`.

When launched through `clare2-agent.sh`, commands run by the agent inherit the
same variable, so `verify-ci.sh` appends to the same session automatically.
The manual `eval` flow above is only needed for shells not started by the
wrapper.

### C. Other agents and external event import
For an agent with lifecycle hooks, configure its user-prompt and completed-turn
events to append compact JSON objects to `$CLARE2_SESSION_FILE`, and launch it
through `clare2-agent.sh`. For non-interactive agents that emit JSONL, wrap the
command and transform its stream into `interaction`, `correction`, or
`decision` records. Do not depend on undocumented agent cache directories.

CI, review bots, and ticket systems can write JSONL into the dated session
directory. Each line must be one object with `type`, UTC `ts`, project context,
and a concise behavioral signal. Never capture credentials, sensitive prompts,
raw proprietary datasets, or unrelated source files.

Validate imports:

```bash
find "$CLARE2_ROOT/corpus/sessions" -name '*.jsonl' -print0 |
  xargs -0 -n1 sh -c 'jq -e . "$0" >/dev/null'
```

## 5. Distill Sessions into Episodes
Distillation runs daily at `22:00 UTC`. Trigger today's pass:

```bash
cd "$CLARE2_ROOT"
TOKEN=$(<secrets/clare2_operator_token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/distill/trigger | jq
sleep 5
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/distill/status | jq
```

The pass reads unprocessed sessions for the UTC date, applies
`clare2/pipeline/prompts/distill.txt`, and writes:

```text
corpus/episodes/YYYY/MM/DD.jsonl
```

Categories are `style`, `architecture`, `antipattern`, and `domain`. Evidence
count 2 is required; corrections are high-signal. Processed session IDs are
stored in `corpus/meta/session_index.json`, preventing duplicate reruns.

## 6. Summarize the Corpus
The `22:30 UTC` schedule performs:

- Sunday: seven daily episode files to a weekly summary
- First of month: prior month's weekly files to a monthly summary
- First day of Jan/Apr/Jul/Oct: prior quarter to quarterly summary and themes

Trigger or backfill a level:

```bash
TOKEN=$(<"$CLARE2_ROOT/secrets/clare2_operator_token")
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference_at":"2026-06-07T22:30:00Z"}' \
  http://127.0.0.1:8000/summarize/weekly | jq
```

Replace `weekly` with `monthly`, `quarterly`, or `scheduled`. Output is under
`corpus/summaries/`. Quarterly processing promotes durable patterns into
`corpus/themes/active/` and archives replaced themes.

## 7. Assemble Training Data
Assembly runs at `23:30 UTC`, combining active themes with seven recent days:

```bash
TOKEN=$(<"$CLARE2_ROOT/secrets/clare2_operator_token")
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/corpus/assemble | jq
wc -l "$CLARE2_ROOT/corpus/training/current.jsonl"
jq . "$CLARE2_ROOT/corpus/training/manifest.json"
head -1 "$CLARE2_ROOT/corpus/training/current.jsonl" | jq
```

Do not train with an empty `current.jsonl`.

## 8. Train, Evaluate, and Promote
The nightly lifecycle drains inference at `23:45 UTC` and trains at `00:00 UTC`.
Start the same flow manually:

```bash
cd "$CLARE2_ROOT"
docker compose exec clare2-policy python -c \
  'from app.lifecycle import drain_and_stop_infer; drain_and_stop_infer()'
docker compose exec clare2-policy python -c \
  'from app.lifecycle import start_training; start_training()'
docker compose logs -f clare2-policy clare2-train vllm-engine
```

Open `http://127.0.0.1:5000` to inspect the `clare2-qlora` experiment. MLflow
stores SQLite metadata under `$CLARE2_ROOT/mlflow/data/` and artifacts under
`$CLARE2_ROOT/mlflow/artifacts/`. It records hashes and training metadata but
does not upload the raw corpus.

Check state or roll back:

```bash
TOKEN=$(<secrets/clare2_operator_token)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/operator/status | jq
"$CLARE2_ROOT/clare2/scripts/clare2-rollback.sh"
```

Promotion requires load/smoke success, all mandatory probes, at least 90% pass
rate, and no category regression.

## 9. Verify and Troubleshoot

```bash
cd "$CLARE2_ROOT"
PYTHONPATH=clare2/pipeline python -m unittest discover -s clare2/pipeline/tests
docker compose config --quiet
curl -s http://127.0.0.1:9091/metrics | grep '^clare2_'
```

- No sessions: check `CLARE2_SESSION_FILE` and the UTC directory date.
- No episodes: inspect policy and local vLLM logs.
- No summaries: verify lower-level files for the reference date.
- Empty training corpus: inspect active themes and seven recent episode files.
- Registry mismatch: recompute hashes before first registry creation.
- Changed model pins: archive incompatible adapters and perform an explicit
  registry migration.

See `README-CLARE2.md` and `CLARE2.md` for architecture and security contracts.
