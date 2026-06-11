# CLARE₂ Architecture

CLARE₂ is CLARE's learning substrate. It turns recurring, verified agent
feedback into an auditable corpus and immutable QLoRA adapters while keeping
adapter choice under deterministic policy control.

## Components

```text
agents -> Temper MCP -> opaque pinned route
agents -> authenticated policy proxy -> private vLLM
                                  |
                                  +-> registry/controller

sessions -> distillation -> corpus -> one-shot trainer -> candidate adapter
                                                     |
nightly lifecycle <----------------------------------+
```

The policy proxy is the only inference endpoint exposed to clients. Raw vLLM,
runtime load/unload APIs, adapter filesystem paths, and Docker control remain on
private networks. Operator endpoints bind to localhost and require a bearer
token. Training completion uses a run-bound HMAC callback.

## Registry

`/models/adapters/registry.json` is atomically written with `fsync` and rename.
It fingerprints the base model and tokenizer, records immutable adapter
provenance and evaluation, and stores `current`/`rollback` references.

Adapter IDs have the form:

```text
clare-<project>-<UTC timestamp>-<corpus hash>
```

The controller rejects duplicate IDs, symlinks and path escapes, wrong base
fingerprints, malformed safetensors, unsupported ranks/modules, and adapters
outside approved lifecycle states.

## Routing

The MCP route tool canonicalizes a configured repository identity, applies
project-capability then global-capability precedence, and falls back to base.
The resolved immutable adapter remains pinned for the route lifetime, including
across promotions.

vLLM loads adapters on demand under immutable IDs. Loads are serialized per
adapter. The controller tracks an eight-entry CPU LRU and never evicts adapters
pinned by active routes. It reconciles registry state with `/v1/models` after
every restart.

## Training

The trainer uses the exact matching non-FP8 Qwen3.5 revision with Unsloth
`FastModel`, 4-bit QLoRA, BF16, rank 32, alpha 64, dropout 0.05, gradient
checkpointing, and a 2048-token initial limit. The first production target set
is text attention only: `q_proj`, `k_proj`, `v_proj`, and `o_proj`.

Corpus records are rendered with the model tokenizer's chat template and
validated after tokenization. Empty datasets and NaN/Inf losses fail the run.
`training_meta.json` records corpus/base/tokenizer/dependency hashes, random
seed, hyperparameters, target modules, skipped reasons, and full loss history.

## Lifecycle

The persisted single-run state machine enters maintenance, drains tracked
requests, stops vLLM, trains, restarts the base, reconciles, loads candidate and
baseline, evaluates deterministic probes, and promotes or rejects atomically.

Promotion requires every mandatory probe, pass rate `>= 0.90`, and no category
regression. Recovery always restores the prior approved adapter before routing
resumes. Rollback updates the registry alias, ensures the target is loaded, and
passes a smoke request before reopening traffic.

## Observability

Metrics cover route decisions, base fallback, adapter operations and latency,
active routes/requests, lifecycle and maintenance, comparative evaluation, and
registry compatibility/reconciliation failures. Audit logs include route,
project, policy rule, immutable adapter, lifecycle run, and outcome, but never
prompts, credentials, or raw training records.
