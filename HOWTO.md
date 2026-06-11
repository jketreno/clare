# CLARE₂ Setup and Operations HOWTO

This guide configures sibling repositories:

```text
/home/you/docker/{clare,ai-vllm}
```

For another layout:

```bash
export CLARE_ROOT=/path/to/clare
export CLARE2_ROOT=/path/to/ai-vllm
```

## 1. Prerequisites
- Docker Compose and NVIDIA Container Toolkit
- A supported NVIDIA GPU with enough memory for Qwen3.5
- Hugging Face access to serving and training checkpoints
- Python 3 and `jq` on developer workstations
- For automated distillation/summarization only: Anthropic access or an
  OpenAI-compatible local model

Runtime endpoints:
- `127.0.0.1:8000`: policy proxy and operator API
- `127.0.0.1:8002`: Temper MCP tools
- private `vllm-engine`: base model and runtime LoRA management
- `corpus/`: sessions, episodes, summaries, themes, and training data
- `models/adapters/registry.json`: adapter source of truth
Inference and training do not require Anthropic; omit a distillation model when
importing prebuilt episodes, themes, or SFT records.

## 2. Configure Models
```bash
cd "$CLARE2_ROOT"
cp .env.example .env
python3 -m venv .venv-config
.venv-config/bin/pip install huggingface_hub transformers
.venv-config/bin/python - <<'PY'
from huggingface_hub import HfApi
api = HfApi()
for model in ("Qwen/Qwen3.5-35B-A3B-FP8", "Qwen/Qwen3.5-35B-A3B"):
    print(model, api.model_info(model).sha)
PY
```

Put the returned pins in `.env`:

```dotenv
CLARE2_INFERENCE_MODEL=Qwen/Qwen3.5-35B-A3B-FP8
CLARE2_INFERENCE_REVISION=<FP8 commit SHA>
CLARE2_TRAIN_MODEL=Qwen/Qwen3.5-35B-A3B
CLARE2_TRAIN_REVISION=<non-FP8 commit SHA>
```

Confirm both commits represent the same upstream model release. Their SHAs can
differ because they are separate Hugging Face repositories.

Generate the training-model fingerprints:

```bash
set -a; source .env; set +a
.venv-config/bin/python - <<'PY'
import hashlib, json, os
from transformers import AutoConfig, AutoTokenizer
model = os.environ["CLARE2_TRAIN_MODEL"]
revision = os.environ["CLARE2_TRAIN_REVISION"]
config = AutoConfig.from_pretrained(model, revision=revision, trust_remote_code=True)
tokenizer = AutoTokenizer.from_pretrained(model, revision=revision, trust_remote_code=True)
digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
print("CLARE2_BASE_CONFIG_HASH=" + digest(config.to_json_string()))
print("CLARE2_TOKENIZER_HASH=" + digest(
    json.dumps(tokenizer.init_kwargs, sort_keys=True, default=str)))
PY
```

Copy the output into `.env`, then define canonical projects:

```dotenv
CLARE2_PROJECT_MAP={"clare":"github:jketreno/clare","service":"github:org/service"}
CLARE2_PROJECT_ID=github:jketreno/clare
```

Agents pass the map key to `clare_temper_route`; adapters store the canonical
value as their project scope.

## 3. Configure Secrets
```bash
cd "$CLARE2_ROOT"
mkdir -p secrets
umask 077
printf '%s' '<Hugging Face token>' > secrets/huggingface_token
printf '%s' '<Anthropic key>' > secrets/anthropic_api_key
printf '%s' '<LDAP password or unused placeholder>' > secrets/ldap_app_password
openssl rand -hex 32 > secrets/clare2_proxy_token
openssl rand -hex 32 > secrets/clare2_operator_token
openssl rand -hex 32 > secrets/clare2_callback_secret
chmod 600 secrets/*
```

Use separate CLARE₂ token values. Rotate credentials previously shared in
plaintext. To distill with the local base model instead of Anthropic:

```dotenv
CLARE2_DISTILL_MODEL=Qwen/Qwen3.5-35B-A3B-FP8
CLARE2_LOCAL_LLM_URL=http://clare2-policy:8000/v1
```

## 4. Build and Start
The lifecycle can only start/stop pre-existing containers through its restricted
Docker proxy. Build and create the trainer before normal startup:

```bash
cd "$CLARE2_ROOT"
docker compose --profile training build
docker compose --profile training create clare2-train
docker compose up -d
docker compose ps
curl -s http://127.0.0.1:8000/health | jq
TOKEN=$(<secrets/clare2_operator_token)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/operator/status | jq
```

`vllm-engine` must have no host-published port.

## 5. Connect Agents
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

## 6. Generate Raw Session Corpus

### A. CLARE verification events
```bash
cd "$CLARE_ROOT"
export CORPUS_ROOT="$CLARE2_ROOT/corpus"
eval "$("$CLARE2_ROOT/clare2/scripts/clare2-session-start.sh")"
./clare/verify-ci.sh
```

This records `session_meta`, `ci_result`, `correction`, and `file_tier` objects
under `corpus/sessions/YYYY/MM/DD/<uuid>.jsonl`. Claude Code users can run
`/project:clare2-capture start`, `status`, and `stop`.

### B. Agent hooks or wrappers
Have start/stop or tool hooks append normalized JSONL to
`$CLARE2_SESSION_FILE`. Useful records include:

```json
{"type":"interaction","ts":"...","request":"Add validation","outcome":"implemented"}
{"type":"correction","ts":"...","problem":"Used mutable state","preferred":"Use immutable updates"}
{"type":"decision","ts":"...","category":"architecture","decision":"Use service layer"}
```

Example correction hook:

```bash
jq -cn --arg ts "$(date -u +%FT%TZ)" \
  --arg problem "$PROBLEM" --arg preferred "$PREFERRED" \
  '{type:"correction",ts:$ts,problem:$problem,preferred:$preferred}' \
  >> "$CLARE2_SESSION_FILE"
```

### C. External event import
CI, review bots, and ticket systems can write JSONL into the dated session
directory. Each line must be one object with `type`, UTC `ts`, project context,
and a concise behavioral signal. Never capture credentials, sensitive prompts,
raw proprietary datasets, or unrelated source files.

Validate imports:

```bash
find "$CLARE2_ROOT/corpus/sessions" -name '*.jsonl' -print0 |
  xargs -0 -n1 sh -c 'jq -e . "$0" >/dev/null'
```

## 7. Distill Sessions into Episodes
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

## 8. Summarize the Corpus
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

## 9. Assemble Training Data
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

## 10. Train, Evaluate, and Promote
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

Check state or roll back:

```bash
TOKEN=$(<secrets/clare2_operator_token)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/operator/status | jq
"$CLARE2_ROOT/clare2/scripts/clare2-rollback.sh"
```

Promotion requires load/smoke success, all mandatory probes, at least 90% pass
rate, and no category regression.

## 11. Verify and Troubleshoot

```bash
cd "$CLARE2_ROOT"
PYTHONPATH=clare2/pipeline python -m unittest discover -s clare2/pipeline/tests
docker compose config --quiet
curl -s http://127.0.0.1:9091/metrics | grep '^clare2_'
```

- No sessions: check `CLARE2_SESSION_FILE` and the UTC directory date.
- No episodes: inspect policy logs and distillation credentials/model.
- No summaries: verify lower-level files for the reference date.
- Empty training corpus: inspect active themes and seven recent episode files.
- Registry mismatch: recompute hashes before first registry creation.
- Changed model pins: archive incompatible adapters and perform an explicit
  registry migration.

See `README-CLARE2.md` and `CLARE2.md` for architecture and security contracts.
