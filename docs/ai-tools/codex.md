# Codex Setup Guide

> CLARE configures Codex through `AGENTS.md` at the repository root. Codex reads this file as project guidance and uses it to apply autonomy boundaries, verification requirements, and testing standards.

---

## Prerequisites

- Codex available in your development environment
- CLARE files copied into your project (see [docs/getting-started.md](../getting-started.md))

---

## How CLARE Configures Codex

### Root `AGENTS.md`

The installer places an `AGENTS.md` file at the project root. It tells Codex to:

- Read `clare/autonomy.yml` before modifying files
- Follow `clare/principles.md`
- Respect `humans-only`, `supervised`, and `full-autonomy` boundaries
- Run `./clare/verify-ci.sh` before reporting implementation work complete
- Treat verification failures as blockers

**Verify it's working:** Start a Codex session and ask "What are your instructions for this project?" It should mention CLARE, `clare/autonomy.yml`, and `clare/verify-ci.sh`.

---

## Recommended Workflow with Codex

```text
You: Implement a user registration endpoint.

Codex:
1. Reads clare/autonomy.yml for affected paths.
2. Checks clare/principles.md for applicable constraints.
3. Generates the implementation and tests.
4. Runs ./clare/verify-ci.sh once.
5. If it fails, fixes the reported failures and runs it once more.
6. Reports the verification result.
```

For sensitive areas, ask Codex to show the autonomy level before editing:

```text
Before modifying any file, tell me the matched rule and autonomy level from clare/autonomy.yml.
```

---

## Skills

If you install CLARE skills during setup, the installer can mirror them into `.codex/skills/<skill-name>/SKILL.md`.

Use those skills directly in prompts:

```text
Use the autonomy-bootstrap skill to draft clare/autonomy.yml boundaries for this repository.
```

---

## Troubleshooting

**Codex does not mention CLARE:**
- Confirm `AGENTS.md` exists at the project root.
- Ask Codex to read `AGENTS.md`, `clare/principles.md`, and `clare/autonomy.yml`.

**Codex does not run verification:**
- Prompt explicitly: "Run `./clare/verify-ci.sh` before reporting complete."
- If terminal execution is restricted, run `./clare/verify-ci.sh` yourself and provide the output.

**Codex tries to edit a `humans-only` path:**
- Ask it to check the matched rule in `clare/autonomy.yml`.
- Keep the path protected and update the boundary only if the policy has changed.
