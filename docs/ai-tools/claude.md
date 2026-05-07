# Claude Code Setup Guide

> CLARE configures Claude Code through `CLAUDE.md` (auto-read at session start) and custom slash commands in `.claude/commands/`.

---

## Prerequisites

- Claude Code installed — see the [official installation guide](https://docs.anthropic.com/en/docs/claude-code/getting-started) for your platform (VS Code extension, JetBrains plugin, or standalone CLI)
- CLARE files copied into your project (see [docs/getting-started.md](../getting-started.md))

---

## How CLARE Configures Claude Code

### Primary: `CLAUDE.md`

Claude Code automatically reads `CLAUDE.md` from the project root at the start of every session — no configuration required. This file contains:

- The verify-ci.sh requirement (non-negotiable)
- Autonomy boundary checking instructions
- Testing standards
- PLAN mode guidance
- Available bash commands

**Verify it's working:** Start a Claude Code session and ask "What are your instructions for this project?" — it should mention CLARE, autonomy.yml, and verify-ci.sh.

### Hierarchical CLAUDE.md (optional)

Claude Code also reads `CLAUDE.md` from subdirectories when you're working in them. You can add subdirectory-specific instructions:

```markdown
<!-- src/api/CLAUDE.md -->
# API Module Instructions

All endpoints in this directory are in the `supervised` autonomy zone.
Always follow clare/examples/skills/api-endpoint.md when creating new endpoints.
Every endpoint must pass the architecture test in tests/architecture/api-rules.test.js.
```

This is especially useful for communicating module-specific skills to Claude.

---

## Custom Slash Commands

CLARE adds three custom commands to `.claude/commands/`:

Default command file contents (installed by CLARE):

```text
.claude/commands/
  verify.md
  check-autonomy.md
  update-autonomy.md
```

```markdown
<!-- .claude/commands/verify.md -->
# /project:verify

Run ./clare/verify-ci.sh.
Return PASS/FAIL plus failing check names and shortest actionable fix list.
```

```markdown
<!-- .claude/commands/check-autonomy.md -->
# /project:check-autonomy [path]

Read clare/autonomy.yml and return matched path rule, level, and reason for [path].
If level is humans-only, refuse code generation and explain why.
```

```markdown
<!-- .claude/commands/update-autonomy.md -->
# /project:update-autonomy

Guide a safe update to clare/autonomy.yml:
1. Confirm path + intended level.
2. Add/update reason.
3. Validate YAML.
4. Run ./clare/verify-ci.sh.
```

### `/project:verify`

Runs `verify-ci.sh` and returns a structured report.

```bash
# In Claude Code:
/project:verify
```

Output format:
```
## Verify CI Results

Status: ✅ PASSED / ❌ FAILED

### Failing Checks
- **ESLint**: 'console' is not allowed (src/api/users.ts:42)
  Fix: Remove console.log or replace with logger.debug()

### Next Step
Shall I fix these issues and run verify again?
```

### `/project:check-autonomy [path]`

Looks up the autonomy level for a file path:

```bash
/project:check-autonomy src/payment/processor.ts
```

Output:
```
## Autonomy Check: src/payment/processor.ts

Matched rule: src/payment
Level: humans-only
Reason: Money movement; AI errors are financial risk

What this means:
I won't generate code in this path. Please make this change yourself.
If the boundary has changed, run /project:update-autonomy to update autonomy.yml.
```

Real output example from this repository:

```text
## Autonomy Check: ORIGIN.md

Matched rule: ORIGIN.md
Level: humans-only
Reason: Historical origin narrative; avoid AI paraphrase that could distort facts
```

### `/project:update-autonomy`

Guides you through updating `clare/autonomy.yml` with a new or modified boundary.

---

## Recommended Workflow with Claude Code

### PLAN mode for new features

```
You: Before implementing, show me the plan for adding user registration.

Claude:
## Plan

**Files to create/modify:**
- src/api/routes/auth.ts — new registration endpoint (supervised)
- src/services/user.service.ts — createUser method (supervised)
- tests/api/auth.test.ts — constraint tests (full-autonomy)

**Autonomy levels:**
- src/api/ → supervised (from clare/autonomy.yml)

**Tests to add:**
- 'never allows duplicate email registration' (property-based)
- 'always validates email format' (invariant)
- 'rate limiter blocks after 10 requests' (constraint)

**Source of truth:**
- User concept derives from database schema (clare/autonomy.yml)

Proceed with implementation?

You: Yes.

Claude: [generates code, runs verify-ci.sh, reports completion]
```

### Session startup best practice

Claude Code automatically reads CLAUDE.md, but you can reinforce the context at session start:

```
You: Read clare/autonomy.yml and summarize the current 
     module boundaries before we start.
```

This is especially useful for long sessions where you're touching multiple modules.

---

## Adding Skills to Claude

### Option 1: Reference from CLAUDE.md

For project-wide skills, add a reference in your `CLAUDE.md`:

```markdown
## Skills

When generating TypeScript types from Python models, follow:
`clare/examples/skills/type-sync.md`

When the user says "update the protos", follow:
`clare/examples/skills/proto-visualization.md`

When creating a new API endpoint, follow:
`clare/examples/skills/api-endpoint.md`
```

Claude will read the skill file when it's relevant.

### Option 2: Custom command per skill

For skills that are invoked explicitly, create a `.claude/commands/` file:

```markdown
<!-- .claude/commands/sync-types.md -->
# /project:sync-types

When invoked, follow clare/examples/skills/type-sync.md exactly to regenerate
TypeScript types from the Python Pydantic models in backend/models/api/.

After regenerating, run ./clare/verify-ci.sh to verify the type
compatibility test passes.
```

Then use it as:
```
/project:sync-types
```

---

## MCP Integration (Advanced)

CLARE's enforcement primitives — `verify-ci.sh` and `autonomy.yml` — can be surfaced as [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) tools, making them available to any MCP-compatible agent or orchestrator as structured tool calls rather than raw bash invocations.

### Why expose CLARE over MCP?

When running multi-agent pipelines (orchestrator + sub-agents, parallel code generation, etc.), individual agents may not share a session context. MCP tools are stateless and discoverable — any agent in the pipeline can call `clare_verify` or `clare_check_autonomy` without needing a loaded CLAUDE.md.

### Available as MCP tools

| MCP Tool | Maps to | Description |
|----------|---------|-------------|
| `clare_verify` | `./clare/verify-ci.sh` | Run all CI checks; returns structured pass/fail + error list |
| `clare_check_autonomy` | `clare/autonomy.yml` lookup | Returns autonomy level for a given file path |
| `clare_list_humans_only` | `clare/autonomy.yml` filter | Lists all `humans-only` paths — safe to call before any batch operation |

### Setting up a CLARE MCP server

Use the skill template at `clare/templates/skills/mcp-server.md` to generate a minimal MCP server that exposes these tools for your project:

```
Follow clare/templates/skills/mcp-server.md to scaffold a CLARE MCP server
for this project. The server should expose:
- clare_verify (runs clare/verify-ci.sh)
- clare_check_autonomy (reads clare/autonomy.yml)
- clare_list_humans_only (filters humans-only paths)
```

Once running, register it in your Claude Code settings or agent configuration as a local MCP server.

### Multi-agent workflow with CLARE

See [docs/agentic.md](../agentic.md) for a complete guide on using CLARE with multi-agent pipelines, including:
- How autonomy boundaries apply across agent chains
- Enforcement patterns for orchestrator + sub-agent workflows
- Pre-flight checks before delegating to a sub-agent

### When to use MCP vs direct CLAUDE.md

| Scenario | Prefer | Why |
|---|---|---|
| Single agent working in one Claude session | CLAUDE.md direct instructions | Lowest setup overhead; instructions are already loaded |
| Multi-agent orchestration (parallel workers) | MCP tools + CLAUDE.md | Shared, typed enforcement across agents and runtimes |
| Headless automation / CI bots | MCP tools (or direct `verify-ci.sh`) | Stateless execution without relying on session context |
| Quick local coding tasks | CLAUDE.md + `/project:*` commands | Fast feedback with minimal configuration |

---

## Troubleshooting

**Claude ignores CLAUDE.md:**
- Ensure `CLAUDE.md` is in the project root (not a subdirectory, unless intentional)
- Ask: "What does CLAUDE.md say about verify-ci.sh?" to test if it was read
- Restart the Claude Code session

**Claude doesn't check autonomy.yml:**
- Reference autonomy.yml explicitly: "Check clare/autonomy.yml before modifying anything"
- The architecture test in `autonomy-guard.test.js` provides mechanical enforcement

**Custom commands not found:**
- Verify `.claude/commands/*.md` files exist
- Commands are discovered by their filename: `verify.md` → `/project:verify`
- Restart Claude Code session after adding new commands

**verify-ci.sh operation fails:**
- Claude needs permission to run terminal commands
- If working in restricted mode: manually run `./clare/verify-ci.sh` and paste the output to Claude
