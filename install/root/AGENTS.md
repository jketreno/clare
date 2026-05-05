# CLEAR — Codex Configuration

This project uses the **CLEAR** framework for AI-assisted development.

## Non-Negotiable Rule

After any file edit (create/update/delete), run:

```bash
./clear/verify-ci.sh
```

If it fails, fix the issues, run it again, and repeat until exit code 0.
Do not report implementation work complete while `./clear/verify-ci.sh` fails.

Before sending a final response for an implementation task, include:
- verify-ci.sh result: PASS/FAIL
- command used
- whether `--fast` or `--fix` was used, if applicable

If running in read-only mode, explicitly state: `verify-ci.sh not run because session is read-only.`

## Session Start Checklist

At the start of every session, before making code changes:

1. Read `clear/autonomy.yml` and identify `humans-only` paths.
2. Read `clear/principles.md`.
3. Check `sources_of_truth` in `clear/autonomy.yml` for relevant domain concepts.

## Autonomy Boundaries

Before modifying any file, check its path in `clear/autonomy.yml`:

| Level | Action |
|-------|--------|
| `full-autonomy` | Proceed freely |
| `supervised` | Generate code, then note that human review is required |
| `humans-only` | Stop. Do not generate code for this path |

If a file is marked `humans-only`, say:

> This path is marked `humans-only` in `clear/autonomy.yml`. I won't generate code here.

## CLEAR Principles

- **Constrained** — Rules are enforced by `clear/verify-ci.sh`.
- **Limited** — Autonomy levels in `clear/autonomy.yml` define editable boundaries.
- **Ephemeral** — Generated files must be regenerated from their source, not hand-edited.
- **Assertive** — Tests should enforce invariants, not confirm current implementation details.
- **Reality-Aligned** — Declared sources of truth in `clear/autonomy.yml` win over assumptions.

## Key Files

- `clear/autonomy.yml` — autonomy boundaries and sources of truth
- `clear/principles.md` — CLEAR principles quick reference
- `clear/verify-ci.sh` — required verification gate before completion
- `clear/verify-local.sh` — project-specific checks
- `clear/templates/skills/` — reference skill templates
