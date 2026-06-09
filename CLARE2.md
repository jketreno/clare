# CLARE₂ Architectural Overview

> **Contextual Learning and Automated Reasoning Engine**
> Version 0.1 — Design Document

---

## Preamble

CLARE₂ is the learning substrate for the CLARE suite. Where CLARE₁ makes constraints enforceable, CLARE₂ makes constraint discovery automatic — observing daily agent sessions, distilling recurring patterns, and training a QLoRA adapter so that knowledge becomes weight rather than context. This document covers two elements in depth: the distillation pipeline and corpus management, and the training system configuration.

---

## Part 1: Distillation Pipeline and Corpus Management

### 1.1 Overview

The distillation system transforms raw daily agent sessions into a progressively compressed, theme-stable corpus that trains the nightly adapter. The key design principle is that knowledge must be *earned through recurrence* — a pattern observed once is noise; a pattern observed across multiple sessions earns its place in the corpus.

```
Daily Sessions (raw JSONL)
    │
    ▼
[Session Distiller]  ← LLM pass, categorized extraction
    │
    ▼
Episode Store  (corpus/episodes/YYYY/MM/DD.jsonl)
    │
    ▼
[Hierarchical Summarizer]  ← weekly → monthly → quarterly compression
    │
    ▼
Theme Extractor  (corpus/themes/active/)
    │
    ▼
Training Corpus  (corpus/training/current.jsonl)
    │
    ▼
Nightly QLoRA → fresh adapter
```

---

### 1.2 Corpus Directory Layout

```
$CLARE2_ROOT/corpus/
├── sessions/                    # Raw captured sessions, write-once
│   └── YYYY/MM/DD/
│       └── <session-id>.jsonl   # One file per agent session
│
├── episodes/                    # Distilled patterns per day
│   └── YYYY/MM/DD.jsonl         # Structured episode records
│
├── summaries/                   # Hierarchical compression tree
│   ├── weekly/
│   │   └── YYYY-WNN.jsonl
│   ├── monthly/
│   │   └── YYYY-MM.jsonl
│   └── quarterly/
│       └── YYYY-QN.jsonl
│
├── themes/
│   ├── active/                  # Current promoted themes (training input)
│   │   ├── style.jsonl
│   │   ├── architecture.jsonl
│   │   ├── antipatterns.jsonl
│   │   └── domain.jsonl
│   └── archive/                 # Retired themes (audit trail)
│       └── YYYY-MM-DD/
│
├── training/
│   ├── current.jsonl            # Active SFT pairs for tonight's run
│   ├── snapshots/               # One per completed training run
│   │   └── YYYY-MM-DD.jsonl
│   └── manifest.json            # Run history, checksums, token counts
│
└── meta/
    ├── drift_log.jsonl          # Theme phrasing evolution over time
    ├── session_index.json       # Fast lookup by date/project
    └── corpus_stats.json        # Running counts per category
```

All files are append-only JSONL except the derived outputs (`current.jsonl`, `active/` themes), which are regenerated each nightly cycle. Git-tracking the `corpus/` directory is recommended for auditability; the `sessions/` subdirectory can be excluded from commits to keep the repo lean.

---

### 1.3 Session Capture Format

Each session capture is a JSONL file with one record per exchange. The session ID is a UUID generated at session start and written to the JSONL header record.

```jsonc
// Header record (type: "session_meta")
{
  "type": "session_meta",
  "session_id": "a3f2...",
  "project": "my-project",           // from CLARE₁ project context
  "started_at": "2025-10-14T09:02:11Z",
  "model": "claude-sonnet-4-20250514",
  "clare1_commit": "abc123"           // CLARE₁ repo HEAD at session start
}

// Exchange records (type: "exchange")
{
  "type": "exchange",
  "seq": 1,
  "role": "user" | "assistant",
  "content": "...",
  "ts": "2025-10-14T09:02:14Z",
  "verify_ci_result": null | { "exit_code": 0 | 1, "checks": [...] }
}

// Correction records (type: "correction") — user overrides, re-explanations
{
  "type": "correction",
  "seq": 4,
  "original_seq": 3,
  "correction_type": "rename" | "style" | "architecture" | "revert" | "explain_again",
  "summary": "User renamed outputData to output_data (snake_case preference)",
  "ts": "2025-10-14T09:03:01Z"
}
```

The `correction` record type is the highest-signal input for distillation — these are explicitly logged whenever the user undoes, renames, re-explains, or overrides the agent.

**Capture integration:** CLARE₂ provides a thin wrapper script `clare2-session-capture` that proxies agent invocations and writes the JSONL stream to `corpus/sessions/`. For Claude Code, this hooks into the slash command layer in `.claude/commands/`.

---

### 1.4 The Distillation Pass

Distillation runs once per day after the final session closes (or on-demand via `/project:distill`). It consumes all sessions from `corpus/sessions/YYYY/MM/DD/` and produces a single `corpus/episodes/YYYY/MM/DD.jsonl`.

**The distillation prompt** instructs an LLM (default: `claude-haiku-4-5` for cost; configurable) to extract categorized patterns:

```
Categories:
  style          — naming conventions, formatting, comment style
  architecture   — module structure, patterns preferred/avoided
  antipattern    — things the agent kept doing wrong
  domain         — project-specific terminology, APIs, constraints

For each extracted pattern, output:
  - category
  - pattern description (1–2 sentences, behaviorally precise)
  - evidence_count (how many times this appeared)
  - canonical_example (the most representative raw exchange snippet)
  - first_seen / last_seen timestamps
```

The `canonical_example` field is critical — it anchors the pattern to a real instance, preventing semantic drift as the pattern is re-summarized in later compression passes.

**Recurrence gate:** A pattern from a single session does NOT enter the episode store unless `evidence_count >= 2` within that session. Patterns from session N that reappear in session N+1 or later automatically pass the gate regardless of per-session count.

---

### 1.5 Hierarchical Summarization

The compression schedule runs as a cron job during low-use hours:

```
Daily:    distillation pass  (after last session)
Sunday:   weekly summarizer  (compress 7 daily episodes → 1 weekly summary)
Month+1:  monthly summarizer (compress ~4 weekly summaries → 1 monthly summary)
Quarter:  quarterly pass     (compress ~3 monthly → 1 quarterly + theme promotion)
```

Each compression level:
1. Reads the N input records for its window
2. Merges records in the same category with similar semantic meaning
3. Increments `evidence_count` for patterns that appeared across inputs
4. Preserves the `canonical_example` from the highest-evidence instance
5. Drops patterns whose `evidence_count` fell below the compression threshold (weekly: ≥2, monthly: ≥3, quarterly: ≥2)

The quarterly pass additionally runs **theme extraction**: it scans all quarterly summaries ever written, identifies patterns that have appeared across multiple quarters, and promotes them into `corpus/themes/active/`. These are the highest-confidence, most stable behavioral signals.

---

### 1.6 Training Corpus Generation

Nightly, before the training run, a corpus assembler generates `corpus/training/current.jsonl` by converting active themes and recent episodes into SFT (supervised fine-tuning) pairs:

```jsonc
{
  "prompt": "...",       // The trigger scenario (what would cause the wrong behavior)
  "completion": "...",   // The correct behavioral response
  "category": "style",
  "weight": 1.0,        // Can be elevated for antipatterns
  "source_theme": "snake_case_naming_v3"
}
```

The SFT pair format follows the model's instruction template (Alpaca, ChatML, or Llama-3 format depending on the base model). Category weights are configurable — `antipattern` defaults to `1.5x` to give corrective signals more training signal than style preferences.

---

### 1.7 CLARE₁ `verify-ci.sh` Enhancements

The `verify-ci.sh` loop in CLARE₁ is already generating high-value training signal — every failure/retry cycle is an implicit correction event. Three enhancements make that signal explicit and consumable by CLARE₂:

**Enhancement 1: Structured CI event emission**

After each `verify-ci.sh` run, append a structured record to the active session's JSONL:

```bash
# In verify-ci.sh, after running checks:
RESULT_JSON=$(jq -n \
  --arg exit_code "$EXIT_CODE" \
  --argjson checks "$CHECKS_ARRAY" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{type:"ci_result", exit_code:$exit_code, checks:$checks, ts:$ts}')

echo "$RESULT_JSON" >> "${CLARE2_SESSION_FILE:-/dev/null}"
```

This requires only that `CLARE2_SESSION_FILE` be set in the environment when CLARE₁ is running inside a CLARE₂ session. Zero-cost when not set.

**Enhancement 2: Failure pattern annotation**

When `verify-ci.sh` exits non-zero and then the same check passes on the next run (the agent self-corrected), emit a `correction` record automatically:

```bash
# Track last-run failures in a temp state file
LAST_FAILURES_FILE="$TMPDIR/.clare1_last_failures"
if [[ -f "$LAST_FAILURES_FILE" ]]; then
  LAST=$(cat "$LAST_FAILURES_FILE")
  RESOLVED=$(comm -23 <(echo "$LAST" | sort) <(echo "$CURRENT_FAILURES" | sort))
  if [[ -n "$RESOLVED" ]]; then
    # Emit correction records for each resolved failure
    for check in $RESOLVED; do
      echo "{\"type\":\"correction\",\"correction_type\":\"ci_self_correct\",
             \"check\":\"$check\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
           >> "${CLARE2_SESSION_FILE:-/dev/null}"
    done
  fi
fi
echo "$CURRENT_FAILURES" > "$LAST_FAILURES_FILE"
```

**Enhancement 3: Autonomy tier correlation**

CLARE₁'s `autonomy.yml` records which modules are `full-autonomy`, `supervised`, or `humans-only`. CLARE₂'s distillation pass should correlate CI failures with the autonomy tier of the file being modified. If a `full-autonomy` module consistently produces CI failures before passing, that's a signal to demote the module to `supervised`. The distillation prompt receives the autonomy tier of each file touched in the session and can include autonomy-demotion candidates in its output.

The enhancement in `verify-ci.sh` is to annotate each check result with the autonomy tier of the modified files:

```bash
# Resolve autonomy tier for changed files
CHANGED_FILES=$(git diff --name-only HEAD)
for f in $CHANGED_FILES; do
  TIER=$(clare1-autonomy-tier "$f")  # new helper script, reads autonomy.yml
  echo "{\"type\":\"file_tier\",\"file\":\"$f\",\"tier\":\"$TIER\"}" \
       >> "${CLARE2_SESSION_FILE:-/dev/null}"
done
```

This closes the loop: CLARE₂ not only observes that the agent failed, but *which files* at *which autonomy level* generated the failure — enabling the recommendation engine to surface tier-demotion candidates in its weekly report.

---

## Part 2: Training System Configuration

### 2.1 Hardware Context

Target platform: **NVIDIA DGX Spark** — 128 GB unified memory (NVLink-C2C), ARM64, 4 TB NVMe. The unified memory pool is both the GPU compute space and the CPU working space, which simplifies the pipeline significantly. There is no GPU↔CPU transfer bottleneck.

The 6-hour training window constraint drives every model and configuration choice below.

---

### 2.2 Model Selection

**Base model: Qwen2.5-Coder-32B-Instruct** (primary recommendation)

The 70B ceiling discussed earlier is technically feasible, but for a nightly-cycle system, 32B is the better operational choice:

| | Qwen2.5-Coder-32B | Llama-3.3-70B |
|---|---|---|
| QLoRA training mem | ~20 GB | ~46–55 GB |
| Inference speed | ~10–15 tok/s | ~2–3 tok/s |
| 6hr training headroom | Generous | Tight |
| Code specialization | Native | General |
| Context window | 128K | 128K |

Qwen2.5-Coder-32B is purpose-built for code agents, has strong instruction following, and at 32B leaves ample memory headroom for the distillation LLM to run in parallel during the day. The 10–15 tok/s interactive inference speed is genuinely usable, unlike 70B's ~2–3 tok/s.

If maximum behavioral depth is preferred over interactive speed, **Llama-3.3-70B-Instruct** is the fallback, accepting the training window risk.

**Distillation model: claude-haiku-4-5** (via API, daytime only)

Distillation runs during low-use hours and does not require a local model. The API call cost for a day's sessions is negligible. If air-gapped operation is required, a local **Qwen2.5-7B** instance handles distillation — it has sufficient instruction-following capability for the structured extraction task.

---

### 2.3 Container Architecture

Three containers, orchestrated by a `docker-compose.yml` (or equivalent systemd units for bare-metal preference):

```
┌──────────────────────────────────────────────────────┐
│  DGX Spark Host                                      │
│                                                      │
│  ┌─────────────────┐   ┌────────────────────────┐   │
│  │  clare2-infer   │   │   clare2-train         │   │
│  │                 │   │                        │   │
│  │  vLLM server    │   │  Unsloth + TRL         │   │
│  │  port 8000      │   │  SFTTrainer            │   │
│  │                 │   │                        │   │
│  │  Serves adapter │   │  Runs 00:00–06:00      │   │
│  │  hot-swappable  │   │  Writes new adapter    │   │
│  └────────┬────────┘   └──────────┬─────────────┘   │
│           │                       │                  │
│  ┌────────▼───────────────────────▼─────────────┐   │
│  │  clare2-pipeline                              │   │
│  │                                               │   │
│  │  Distillation, summarization, corpus mgmt    │   │
│  │  FastAPI control plane (port 8080)           │   │
│  │  Prometheus metrics exporter (port 9090)     │   │
│  └───────────────────────────────────────────────┘   │
│                                                      │
│  Shared volumes:                                     │
│    /corpus        → bind mount to $CLARE2_ROOT/corpus│
│    /models        → base model weights + adapters    │
│    /logs          → structured JSON logs             │
└──────────────────────────────────────────────────────┘
```

**`clare2-infer`** — Inference container

Base image: `nvcr.io/nvidia/vllm:latest` (ARM64 / Blackwell build)

- Loads base model + current LoRA adapter at startup
- Exposes OpenAI-compatible API on port 8000
- Accepts adapter hot-swap via `/v1/load_lora_adapter` (vLLM supports this natively)
- Does not run during the 00:00–06:00 training window; a `pre-stop` hook waits for in-flight requests to drain

```yaml
# docker-compose excerpt
clare2-infer:
  image: vllm/vllm-openai:latest
  runtime: nvidia
  environment:
    - MODEL_PATH=/models/base
    - LORA_ADAPTER_PATH=/models/adapters/current
    - ENABLE_LORA=true
    - MAX_LORA_RANK=64
  volumes:
    - ./models:/models:ro
    - ./corpus:/corpus:ro
  ports:
    - "8000:8000"
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
    interval: 30s
```

**`clare2-train`** — Training container

Base image: custom, based on `nvcr.io/nvidia/pytorch:25.xx-py3` with Unsloth installed.

- Scheduled via the pipeline container's cron (not a persistent service)
- Reads `corpus/training/current.jsonl`
- Resets adapter from scratch each run (no incremental update)
- Writes completed adapter to `/models/adapters/YYYY-MM-DD/`
- Signals pipeline container when complete; pipeline atomically symlinks `current` → new adapter

```bash
# Training entrypoint (train.sh)
#!/bin/bash
set -euo pipefail

CORPUS=/corpus/training/current.jsonl
ADAPTER_OUT=/models/adapters/$(date +%Y-%m-%d)
BASE_MODEL=/models/base

python train.py \
  --model_name_or_path "$BASE_MODEL" \
  --train_file "$CORPUS" \
  --output_dir "$ADAPTER_OUT" \
  --load_in_4bit true \
  --lora_r 32 \
  --lora_alpha 64 \
  --lora_dropout 0.05 \
  --target_modules q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj \
  --num_train_epochs 3 \
  --per_device_train_batch_size 4 \
  --gradient_accumulation_steps 4 \
  --learning_rate 2e-4 \
  --warmup_ratio 0.03 \
  --lr_scheduler_type cosine \
  --logging_steps 10 \
  --save_strategy epoch \
  --bf16 true \
  --max_seq_length 2048 \
  --report_to prometheus  # custom metrics exporter (see §2.5)
```

Key training hyperparameters rationale:
- `lora_r=32` — conservative rank for behavioral nudges; not trying to rewire the model
- `learning_rate=2e-4` — standard for QLoRA behavioral fine-tuning; lower than factual SFT
- `max_seq_length=2048` — respects the 70B memory warning; 32B has headroom for 4096 if sessions are long
- `num_train_epochs=3` — sufficient for a small corpus; early stopping if loss plateaus

**`clare2-pipeline`** — Orchestration and control plane

Base image: `python:3.12-slim`

- FastAPI control plane for triggering distillation, querying corpus stats, and initiating training
- Celery task queue (backed by Redis) for async distillation and summarization jobs
- APScheduler for cron: daily distillation at 22:00, weekly summarizer Sunday 23:00, training at 00:00
- Prometheus metrics endpoint on port 9090

---

### 2.4 Adapter Lifecycle Management

```
/models/
├── base/                      # Base model weights, read-only, never modified
│   └── (Qwen2.5-Coder-32B weights)
│
├── adapters/
│   ├── 2025-10-14/            # Each nightly run produces a dated directory
│   │   ├── adapter_config.json
│   │   ├── adapter_model.safetensors
│   │   └── training_meta.json  # corpus token count, loss curve, duration
│   ├── 2025-10-15/
│   │   └── ...
│   ├── current -> 2025-10-15/  # Symlink; atomic update after training completes
│   └── rollback -> 2025-10-14/ # Previous adapter; auto-set before each training run
```

The rollback pointer allows a one-command revert if the new adapter behaves poorly:

```bash
# clare2-rollback.sh
ln -sfn "$(readlink /models/adapters/rollback)" /models/adapters/current
curl -X POST http://localhost:8000/v1/load_lora_adapter \
     -d '{"lora_name":"current","lora_path":"/models/adapters/current"}'
```

Adapters older than 30 days are pruned by a weekly cleanup job, keeping the most recent adapter for each month-end as a long-term snapshot.

---

### 2.5 Observability

Observability is non-optional for a system that modifies its own weights nightly. Silent quality degradation is the failure mode most likely to go undetected.

**Metrics (Prometheus + Grafana)**

The pipeline container exports these metrics on port 9090:

```
# Corpus health
clare2_episodes_total{category}         # cumulative episode count by category
clare2_themes_active{category}          # active themes currently in training corpus
clare2_corpus_tokens_total              # total SFT tokens in current.jsonl

# Training run
clare2_training_duration_seconds        # wall time for last training run
clare2_training_loss_final              # final training loss
clare2_training_loss_by_epoch{epoch}    # per-epoch loss curve
clare2_adapter_size_bytes               # adapter weight file size

# Distillation quality
clare2_distillation_patterns_extracted{category}  # patterns found per day
clare2_distillation_patterns_gated_out            # patterns dropped by recurrence gate
clare2_theme_drift_events               # times a theme's phrasing changed significantly

# Inference
clare2_inference_requests_total         # served by vLLM (from its native metrics)
clare2_adapter_hot_swap_duration_seconds
```

**Drift detection**

The `drift_log.jsonl` records how theme descriptions change across summarization cycles. A Prometheus gauge `clare2_theme_drift_events` increments whenever the cosine similarity between a theme's current phrasing and its `canonical_example` drops below 0.85 (computed using a local sentence-transformer). This catches the semantic drift failure mode early.

**Weekly digest**

The pipeline generates a `corpus/meta/weekly_report_YYYY-WNN.md` every Sunday containing:
- New themes promoted this week
- Themes that were compressed away (recurrence fell below threshold)
- CI failure patterns with their autonomy-tier correlation
- Autonomy demotion candidates (modules with ≥3 CI failures in the week)
- Training loss trend (is the adapter getting better, plateauing, or degrading?)
- Adapter quality proxy: a fixed eval suite of 20 behavioral prompts run against the new adapter each morning, with pass/fail tracked over time

**Structured logging**

All pipeline components write JSON logs to `/logs/`. Format:

```json
{
  "ts": "2025-10-14T22:01:44Z",
  "level": "info",
  "component": "distiller",
  "event": "episode_written",
  "session_id": "a3f2...",
  "patterns_extracted": 7,
  "patterns_gated": 2,
  "duration_ms": 4312
}
```

Log rotation: daily, 30-day retention. Grafana Loki is the recommended aggregation target if a full observability stack is desired; otherwise `jq` over the raw files is sufficient for a single-node deployment.

---

### 2.6 Scheduling and Boot Sequence

```
22:00  Pipeline: distillation pass (all sessions from today)
22:30  Pipeline: summarization jobs (weekly/monthly/quarterly as scheduled)
23:30  Pipeline: corpus assembler generates training/current.jsonl
23:45  Pipeline: signals infer container to drain and stop
00:00  Training: container starts, begins QLoRA run
~05:00 Training: completes (estimated; 32B on DGX Spark ≈ 3–5 hours for typical corpus)
05:00  Pipeline: validates adapter (run eval suite)
05:15  Pipeline: atomically updates current symlink
05:20  Infer: container restarts, loads new adapter
06:00  Normal operation resumes
```

**Thermal safety:** DGX Spark thermal throttling under sustained load is a known risk. The training container sets `CUDA_VISIBLE_DEVICES` appropriately and the training script checkpoints every epoch. A watchdog in the pipeline container monitors GPU temperature via `nvidia-smi` and will pause training (gradient accumulation step increase) if temperature exceeds 90°C, resume when it drops to 80°C. This extends training time but prevents hard shutdowns.

---

### 2.7 Integration with CLARE₁

CLARE₂ integrates with CLARE₁ as a skill, not a replacement. The integration surface is minimal by design:

```
.claude/commands/distill.md       # /project:distill slash command
.claire2/config.yml               # per-project CLARE₂ config (model, categories, weights)
verify-ci.sh                      # enhanced per §1.7 (CLARE2_SESSION_FILE env var)
```

The `.claire2/config.yml` per-project file allows category weight overrides, distillation model selection, and opt-out of specific pattern categories (e.g., a project may not want `style` patterns trained in if the codebase has multiple contributors with legitimately different styles).

---

## Summary

CLARE₂ closes the loop that CLARE₁ opens. CLARE₁ makes the agent's failures visible and verifiable. CLARE₂ turns those failures into weight. The corpus distillation pipeline ensures only earned, recurring knowledge reaches the adapter. The nightly adapter reset ensures that knowledge stays auditable and resettable. The observability layer ensures quality degradation is detected before it compounds.

The three principles that should govern every implementation decision:

> **Earned through recurrence.** No single session creates a training signal alone.
> **Compressed, not accumulated.** The corpus shrinks over time as noise is filtered; only stable themes survive.
> **Inspectable and resettable.** Every adapter has a provenance trail, and one command returns to yesterday.
