# CLARE — Codex Configuration

This project uses the **CLARE** framework for AI-assisted development.

## Non-Negotiable Rule

After any file edit (create/update/delete), run:

```bash
./clare/verify-ci.sh
```

If it fails, fix the issues, run it again, and repeat until exit code 0.
Do not report implementation work complete while `./clare/verify-ci.sh` fails.

Before sending a final response for an implementation task, include:
- verify-ci.sh result: PASS/FAIL
- command used
- whether `--fast` or `--fix` was used, if applicable

If running in read-only mode, explicitly state: `verify-ci.sh not run because session is read-only.`

## Session Start Checklist

At the start of every session, before making code changes:

1. Read `clare/autonomy.yml` and identify `humans-only` paths.
2. Read `clare/principles.md`.
3. Check `sources_of_truth` in `clare/autonomy.yml` for relevant domain concepts.

## Autonomy Boundaries

Before modifying any file, check its path in `clare/autonomy.yml`:

| Level | Action |
|-------|--------|
| `full-autonomy` | Proceed freely |
| `supervised` | Generate code, then note that human review is required |
| `humans-only` | Stop. Do not generate code for this path |

If a file is marked `humans-only`, say:

> This path is marked `humans-only` in `clare/autonomy.yml`. I won't generate code here.

## CLARE Principles

- **Constrained** — Rules are enforced by `clare/verify-ci.sh`.
- **Limited** — Autonomy levels in `clare/autonomy.yml` define editable boundaries.
- **Assertive** — Tests should enforce invariants, not confirm current implementation details.
- **Reality-Aligned** — Declared sources of truth in `clare/autonomy.yml` win over assumptions.
- **Ephemeral** — Generated files must be regenerated from their source, not hand-edited.

## Key Files

- `clare/autonomy.yml` — autonomy boundaries and sources of truth
- `clare/principles.md` — CLARE principles quick reference
- `clare/verify-ci.sh` — required verification gate before completion
- `clare/verify-local.sh` — project-specific checks
- `clare/templates/skills/` — reference skill templates
