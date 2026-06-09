![CLARE](assets/clare.png)

# CLARE₂ — The Learning Substrate

CLARE₂ closes the loop that CLARE₁ opens. CLARE₁ makes AI agent failures visible
and enforceable via `verify-ci.sh`. CLARE₂ turns those failures — and the daily
corrections you make to AI-generated code — into QLoRA training signal that
reshapes a local model overnight into "the Temper": a small adapter shaped by
*this project's* conventions, anti-patterns, and vocabulary.

The Temper is not accumulated indefinitely. It is **reset and recast each
night** from a freshly assembled corpus, so it tracks where the project is now,
not where it was three months ago.

This document covers day-to-day operation: generating the corpus, scheduling
and running training, and loading the result into vLLM. For the architectural
rationale, see [CLARE2.md](CLARE2.md) and [WHY-CLARE2.md](WHY-CLARE2.md).

> Background reading: [README.md](README.md) for CLARE₁ itself.

---

## How the pieces fit together

CLARE₂ lives alongside the existing `ai-vllm/` Docker Compose stack as four
additional services:

| Service | Role | Port |
|---|---|---|
| `redis` | Celery broker for the pipeline | internal only |
| `clare2-pipeline` | Always-on FastAPI control plane: distillation, summarization, corpus assembly, training orchestration, eval | 8090 (API), 9091 (metrics) |
| `clare2-infer` | vLLM serving the base model + the current Temper LoRA adapter | 8001 |
| `clare2-train` | Ephemeral one-shot training container, started by the pipeline | n/a (`profiles: [training]`, never auto-starts) |

All persistent state lives under `ai-vllm/corpus/` (the training corpus,
sessions, summaries, themes) and `ai-vllm/models/` (base weights and adapters),
both bind-mounted into the relevant containers.

```
ai-vllm/
├── docker-compose.yml
├── .env                        # CLARE2_* configuration
├── clare2/
│   ├── pipeline/               # control-plane container
│   ├── train/                  # training container
│   └── scripts/                # clare2-rollback.sh, clare2-session-start.sh
├── corpus/                     # generated corpus (bind-mounted)
│   ├── sessions/YYYY/MM/DD/
│   ├── episodes/YYYY/MM/DD.jsonl
│   ├── summaries/{weekly,monthly,quarterly}/
│   ├── themes/{active,archive}/
│   ├── training/{current.jsonl,snapshots/,manifest.json}
│   └── meta/{session_index.json,corpus_stats.json,eval_*.json}
└── models/
    ├── base/                   # base model weights (CLARE2_BASE_MODEL_PATH)
    └── adapters/
        ├── current -> YYYY-MM-DD/   # symlink, swapped atomically after training
        ├── rollback -> YYYY-MM-DD/  # previous adapter, for one-command rollback
        └── YYYY-MM-DD/{adapter_config.json,adapter_model.safetensors,training_meta.json}
```

---

## 1. Configuration

All CLARE₂ settings live in `ai-vllm/.env`:

```bash
# Base model — the HuggingFace model ID to use as the Temper base.
# CLARE2_BASE_MODEL_PATH must point to where those weights live on the host
# (bind-mounted read-only to /models/base in the train and infer containers).
CLARE2_BASE_MODEL_PATH=/models/base
CLARE2_BASE_MODEL_NAME=Qwen2.5-Coder-32B-Instruct

# QLoRA hyperparameters
CLARE2_LORA_R=32
CLARE2_LORA_ALPHA=64
CLARE2_MAX_SEQ_LENGTH=2048
CLARE2_GPU_MEMORY_UTILIZATION=0.70

# Service ports
CLARE2_INFER_PORT=8001
CLARE2_PIPELINE_PORT=8090
CLARE2_METRICS_PORT=9091

# Distillation LLM — claude-haiku-4-5 for hosted use; point at a local
# OpenAI-compatible model name for an air-gapped setup.
ANTHROPIC_API_KEY=sk-ant-...
CLARE2_DISTILL_MODEL=claude-haiku-4-5
```

Place your base model weights at `CLARE2_BASE_MODEL_PATH` (default
`/models/base`, which maps to `ai-vllm/models/base/` on the host) before
starting any CLARE₂ service — both `clare2-train` and `clare2-infer` expect
them there.

Bring up the always-on services:

```bash
cd ai-vllm
docker compose up -d redis clare2-pipeline clare2-infer
```

`clare2-train` is defined with `profiles: [training]` and intentionally does
**not** start with the command above — it only runs when the pipeline launches
it for a nightly (or manual) training pass.

---

## 2. Generating the corpus

The corpus is built bottom-up from raw session captures, through several
compression stages, gated by recurrence so that one-off events don't bias
training.

### 2.1 — Capture a session

Sessions are the raw material. Start a capture at the beginning of an agent
session with the slash command:

```
/project:clare2-capture start
```

This runs `ai-vllm/clare2/scripts/clare2-session-start.sh`, which:

- generates a session UUID
- creates `ai-vllm/corpus/sessions/YYYY/MM/DD/<uuid>.jsonl`
- writes a `session_meta` header record
- exports `CLARE2_SESSION_FILE` and `CLARE2_SESSION_ID` into your shell

While `CLARE2_SESSION_FILE` is set, `clare/verify-ci.sh` appends structured
JSONL records to it on every run:

- **`ci_result`** — pass/fail outcome of each check stage
- **`correction`** — emitted when a previously failing check (`ci_self_correct`)
  passes on a later run, i.e. the agent fixed its own mistake
- **`file_tier`** — the `clare/autonomy.yml` autonomy tier of each file touched
  in the session (`full-autonomy`, `supervised`, `humans-only`)

This is the signal CLARE₂ learns from: not just "what code did the agent
write" but "what did the agent get wrong, and how did it self-correct."

End the capture with:

```
/project:clare2-capture stop
```

or check its state with `/project:clare2-capture status`.

### 2.2 — Daily distillation

Each night at **22:00 UTC**, the pipeline's `distiller.run_daily()` reads that
day's session files, sends them to the configured LLM
(`CLARE2_DISTILL_MODEL`) with the extraction prompt in
`ai-vllm/clare2/pipeline/prompts/distill.txt`, and asks it to identify
recurring behavioral patterns in four categories: `style`, `architecture`,
`antipattern`, `domain`.

A pattern only survives if its `evidence_count` meets the **recurrence gate**
(≥ 2 within the session). One-off events are dropped — CLARE₂ trains on
*patterns*, not anecdotes. Surviving patterns are appended to
`ai-vllm/corpus/episodes/YYYY/MM/DD.jsonl`, and `corpus_stats.json` /
`session_index.json` under `corpus/meta/` are updated.

You can trigger this on demand instead of waiting for the cron:

```
/project:distill
```

which POSTs to `clare2-pipeline:8090/distill/trigger`, polls
`/distill/status`, and reports the patterns extracted (and any dropped by the
recurrence gate).

### 2.3 — Hierarchical summarization

At **22:30 UTC**, `summarizer.run_scheduled()` rolls daily episodes up into
weekly / monthly / quarterly summaries (and promotes long-lived patterns into
**themes**), each with its own recurrence gate:

| Level | Gate (evidence_count ≥) | Output |
|---|---|---|
| Weekly | 2 | `corpus/summaries/weekly/` |
| Monthly | 3 | `corpus/summaries/monthly/` |
| Quarterly | 2 | `corpus/summaries/quarterly/` |
| Theme promotion | — | `corpus/themes/active/` (demoted patterns move to `themes/archive/`) |

Each level uses an LLM merge pass (`_call_llm_merge`) to consolidate similar
patterns rather than naively concatenating them, so the corpus compresses as
it ages instead of growing without bound.

### 2.4 — Corpus assembly

At **23:30 UTC**, `corpus.assemble()` builds the actual SFT training set:

- loads all **active themes** plus the last **7 days** of episodes
- converts each pattern into a `{prompt, completion, category, weight,
  source_theme}` SFT pair
- applies category weights (`antipattern` patterns are weighted 1.5×, since
  "don't do X" corrections are the highest-value training signal; `style`,
  `architecture`, `domain` are weighted 1.0×)
- snapshots the previous `current.jsonl` into `corpus/training/snapshots/`
  before overwriting it
- updates `corpus/training/manifest.json` (run history, pair/token counts)

You can inspect the assembled corpus directly:

```bash
wc -l ai-vllm/corpus/training/current.jsonl
cat  ai-vllm/corpus/training/manifest.json
```

or trigger an out-of-cycle assembly via `POST /corpus/assemble` on the
pipeline API.

---

## 3. Scheduling and running training

### 3.1 — The nightly cycle

The pipeline registers all of this as APScheduler cron jobs on startup
(`pipeline/app/main.py`):

```
22:00  distiller.run_daily()          — distill today's sessions → episodes
22:30  summarizer.run_scheduled()     — weekly/monthly/quarterly as due
23:30  corpus.assemble()              — write training/current.jsonl
23:45  lifecycle.drain_and_stop_infer() — stop clare2-infer to free the GPU
00:00  lifecycle.start_training()     — docker run clare2-train (one-shot)
```

`start_training()` launches the `clare2-train` container via the Docker SDK
(the pipeline mounts `/var/run/docker.sock` read-only for this purpose) with
the assembled corpus mounted read-only and `models/` mounted read-write.

### 3.2 — What the training container does

`clare2-train` (`ai-vllm/clare2/train/`):

1. `train.sh` computes `ADAPTER_DATE=$(date -u +%Y-%m-%d)` and verifies the
   corpus is non-empty
2. runs `train.py`, which uses **Unsloth** + **TRL's `SFTTrainer`** to run a
   QLoRA fine-tune:
   - 4-bit quantized base model load (`FastLanguageModel.from_pretrained`)
   - `lora_r=${CLARE2_LORA_R}`, `lora_alpha=${CLARE2_LORA_ALPHA}`
   - corpus records reformatted as ChatML (`<|im_start|>user ... <|im_end|>`)
   - per-epoch loss tracked via an `EpochLossCallback`
3. on completion, writes `training_meta.json` (adapter date, base model,
   pair count, hyperparameters, final/per-epoch loss, duration) alongside the
   adapter weights at `models/adapters/YYYY-MM-DD/`
4. `train.sh` extracts `final_loss` and POSTs a completion webhook to
   `${CLARE2_PIPELINE_URL}/training/done`

Because the container is reset from the base model every night — never
fine-tuned incrementally on top of yesterday's adapter — the Temper always
reflects a clean QLoRA pass over the *current* corpus. There is no drift from
repeated fine-tuning generations.

### 3.3 — Running it manually / out of cycle

To force a training run without waiting for midnight (useful after manually
assembling a corpus, or when iterating on `train.py`):

```bash
cd ai-vllm
docker compose run --rm clare2-train
```

Note that running it this way bypasses the pipeline lifecycle (drain →
train → eval → swap → restart) — `clare2-infer` keeps running, competing for
GPU memory, and the resulting adapter won't be evaluated or swapped in
automatically. For a full end-to-end pass outside the nightly schedule, it's
best to let the pipeline drive it — e.g. by adjusting the cron temporarily, or
by invoking `lifecycle.start_training()` directly inside the
`clare2-pipeline` container.

### 3.4 — Post-training evaluation

When the pipeline receives the `/training/done` webhook
(`_finalize_training()` in `main.py`), it first runs the **20-probe eval
suite** (`evaluator.run_eval_suite`) defined in
`ai-vllm/clare2/pipeline/prompts/eval_probes.jsonl`. Each probe is sent to the
freshly trained adapter (loaded as model `"temper"`) and checked against an
`expected_keyword`. The report is written to
`corpus/meta/eval_<adapter_date>.json`.

Only after the eval report is written does the pipeline proceed to swap the
adapter into service.

---

## 4. Loading the fine-tuned adapter into vLLM

### 4.1 — Automatic hot-swap (the normal path)

`lifecycle.on_training_done(adapter_date, loss)`:

1. validates the new adapter directory (`adapter_config.json` +
   `adapter_model.safetensors` present)
2. atomically repoints the `models/adapters/current` symlink at the new
   `YYYY-MM-DD/` directory, and moves the *previous* `current` target to
   `models/adapters/rollback`
3. restarts (or hot-reloads, via vLLM's `/v1/load_lora_adapter` endpoint)
   `clare2-infer`

`clare2-infer` is started with `--enable-lora` and
`--lora-modules temper=/models/adapters/current`, so once the symlink swap and
reload complete, requests to model `"temper"` on port `${CLARE2_INFER_PORT}`
(default `8001`) are served by the new adapter — with zero change to client
configuration, since the path is stable and only the symlink target changes.

Verify which adapter is currently live:

```bash
curl http://localhost:8090/adapter/current
```

### 4.2 — Querying the Temper directly

Once swapped in, the Temper is just another OpenAI-compatible model:

```bash
curl http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "temper",
    "messages": [{"role": "user", "content": "How should I structure a new architecture test in this repo?"}]
  }'
```

### 4.3 — Rollback

If a freshly trained adapter performs worse (low eval pass rate, regressions
in day-to-day use), roll back to the previous one with one command:

```bash
./ai-vllm/clare2/scripts/clare2-rollback.sh
```

This calls the pipeline's `POST /adapter/rollback` (which swaps the
`current`/`rollback` symlinks back and restarts `clare2-infer`), or falls back
to a manual `ln -sfn` swap if the pipeline API is unreachable. Use
`--dry-run` to see what it would do without changing anything.

---

## 5. Observability

- **Metrics** — Prometheus endpoint at `http://localhost:9091/metrics`
  (`clare2-pipeline`), exposing corpus health (`episodes_total`,
  `themes_active`, `corpus_tokens_total`), training health
  (`training_duration_seconds`, `training_loss_final`,
  `training_loss_by_epoch`, `adapter_size_bytes`), distillation quality
  (`distillation_patterns_extracted`, `distillation_patterns_gated_out`,
  `theme_drift_events`), and adapter lifecycle
  (`adapter_hot_swap_duration_seconds`). Add `clare2-pipeline:9091` as a
  Prometheus scrape target if you run Grafana alongside the stack.
- **Logs** — structured JSON logs under `ai-vllm/logs/clare2/` (bind-mounted,
  same pattern as the existing stack's logs).
- **Health** — `curl http://localhost:8090/health` for the pipeline,
  `curl http://localhost:8001/v1/models` for the inference service.

---

## 6. Quick command reference

```bash
# Bring up the always-on CLARE₂ services
cd ai-vllm && docker compose up -d redis clare2-pipeline clare2-infer

# Capture a session (run before starting AI-assisted work)
/project:clare2-capture start
/project:clare2-capture stop
/project:clare2-capture status

# Trigger an on-demand distillation pass
/project:distill

# Force corpus assembly without waiting for the nightly cron
curl -X POST http://localhost:8090/corpus/assemble

# Manually run a training pass
cd ai-vllm && docker compose run --rm clare2-train

# Check / change the live adapter
curl http://localhost:8090/adapter/current
./ai-vllm/clare2/scripts/clare2-rollback.sh [--dry-run]

# Query the Temper
curl http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "temper", "messages": [{"role": "user", "content": "..."}]}'
```
