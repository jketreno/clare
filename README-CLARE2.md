# CLARE₂ Operations

CLARE₂ distills agent sessions and trains immutable QLoRA Temper adapters. Its
inference path shares the existing Qwen3.5 vLLM service through an authenticated
policy proxy; agents never access vLLM management routes, adapter paths, Docker,
or mutable adapter aliases.

For deployment and corpus operations, see [HOWTO.md](HOWTO.md).

## Runtime

The sibling `ai-vllm` repository contains:

- `clare2-policy`: OpenAI-compatible proxy, registry controller, lifecycle, and operator API.
- `clare2-mcp`: route/status/list tools for agents.
- `vllm-engine`: private Qwen3.5 FP8 inference with runtime LoRA enabled.
- `clare2-train`: one-shot Qwen3.5 non-FP8 rank-32 QLoRA training.
- `docker-socket-proxy`: restricted container inspect/start/stop access.

`models/adapters/registry.json` is authoritative. `current` and `rollback` are
registry references; filesystem symlinks are not used for serving.

## Request Flow

1. Call `clare_temper_route(project, task_kind, capabilities)`.
2. Keep the opaque route ID for the agent session.
3. Send it as `X-CLARE-Route-ID` to the policy proxy on localhost port `8000`.
4. The proxy validates the route, loads its pinned immutable adapter if needed,
   overwrites `model`, and forwards only an allowed inference endpoint.

No route means base Qwen3.5. Agents cannot request an adapter ID or path.

## Nightly Flow

```text
drain -> stop inference -> train -> restart base -> load candidate/current
-> compare -> promote or reject -> resume
```

The lifecycle is persisted and single-run. New requests receive `503` with
`Retry-After` during maintenance; existing requests are tracked until drained.
Promotion requires load and smoke success, all mandatory probes, at least 90%
overall pass rate, and no category regression against the current adapter (or
base model for the first candidate).

On failure, CLARE₂ marks the run failed, restarts the prior approved adapter,
restores routing, and retains candidate artifacts.

## Training Contract

Training uses the exact non-FP8 `Qwen/Qwen3.5-35B-A3B` revision matching the
FP8 serving checkpoint, Unsloth `FastModel`, 4-bit QLoRA, BF16 compute, rank 32,
alpha 64, dropout 0.05, gradient checkpointing, and a 2048-token limit.
Only `q_proj`, `k_proj`, `v_proj`, and `o_proj` are targeted.

The trainer uses the tokenizer chat template, validates tokenized records,
rejects an empty dataset and non-finite loss, and records complete provenance in
`training_meta.json`.

See the `ai-vllm/README.md` runbook for deployment, secrets, operator APIs,
verification, and GPU acceptance.
