# VS Code + GitHub Copilot Setup Guide

> CLARE works with GitHub Copilot through workspace instruction files and VS Code tasks. No extensions beyond Copilot itself are required to get started.

---

## Prerequisites

- VS Code with GitHub Copilot extension installed and signed in
- CLARE files copied into your project (see [docs/getting-started.md](../getting-started.md))

---

## How CLARE Configures Copilot

### Primary: `.github/copilot-instructions.md`

This file is automatically read by Copilot Chat at the start of every session. It contains the complete CLARE workflow: autonomy boundary checking, verify-ci.sh requirements, testing standards, and more.

**Verify it's working:** Open Copilot Chat and ask "What are your instructions for this project?" — it should mention CLARE and verify-ci.sh.

### Targeted: `.github/instructions/*.instructions.md`

Scoped instruction files that apply only to specific file patterns:

| File | Applies To | Content |
|------|-----------|---------|
| `scripts.instructions.md` | `scripts/**` | Bash scripting rules (safety flags, quoting, etc.) |
| `tests.instructions.md` | `**/*.test.*`, `tests/**` | Assertive testing: invariants, not confirmations |

Add your own scoped instructions for other file types:

```markdown
---
applyTo: "src/api/**"
---
# API Development Rules
All endpoints must include rate limiting, authentication, and input validation.
Follow clare/examples/skills/api-endpoint.md for the complete template.
```

### Enable Instruction Files

Make sure this setting is on in VS Code:

```json
// .vscode/settings.json (already configured)
Or via the UI: File -> Preferences -> Settings -> Extensions -> GitHub Copilot Chat -> Code Generation: Use Instruction Files.

Verification checklist:
1. Open Settings JSON and confirm `"github.copilot.chat.codeGeneration.useInstructionFiles": true`.
2. Open Copilot Chat and ask: "List the instruction files currently applied in this workspace."
3. Confirm responses reference `.github/copilot-instructions.md` and relevant `.github/instructions/*.instructions.md` files.
```

Or via the UI: Settings → search "copilot instruction" → enable "Use Instruction Files".

---

## VS Code Tasks

CLARE adds tasks to `Ctrl/Cmd + Shift + P` → "Tasks: Run Task":

| Task | Shortcut | What it does |
|------|---------|-------------|
| **CLARE: Verify CI** | Default test task | Runs `./clare/verify-ci.sh` |
| **CLARE: Verify CI (fast)** | — | Skips architecture tests |
| **CLARE: Verify CI (fix)** | — | Auto-fixes lint issues |
| **CLARE: Setup** | — | Runs the setup wizard |
| **CLARE: Show Autonomy Boundaries** | — | Displays `clare/autonomy.yml` |

**Bind to a keyboard shortcut** for faster access:

```json
// keybindings.json (Ctrl/Cmd + Shift + P → "Open Keyboard Shortcuts (JSON)")
{
  "key": "ctrl+alt+v",       // pick a non-conflicting key for your platform
  "command": "workbench.action.tasks.runTask",
  "args": "CLARE: Verify CI"
}
```

Installer note:
- CLARE pre-installs `.github/copilot-instructions.md` plus two scoped instruction files:
  - `.github/instructions/scripts.instructions.md`
  - `.github/instructions/tests.instructions.md`
- Any additional `.github/instructions/*.instructions.md` files are project-specific and should be added manually.

**Make it the default test task:**

The CLARE: Verify CI task is already set as `"isDefault": true` in the `test` group. This means `Ctrl/Cmd + Shift + P` → "Run Test Task" will run verify-ci.sh.

---

## Recommended Workflow with Copilot Chat

### For new features

```
You (in Copilot Chat): Implement a user registration endpoint.

Copilot (reads copilot-instructions.md):
1. Checks clare/autonomy.yml for src/api — supervised
2. Generates endpoint following api-endpoint.md skill
3. Generates tests following tests.instructions.md rules
4. Runs verify-ci.sh
5. Reports: "Complete. All checks pass. ⚠ Human review required (supervised path)"
```

### For refactors

```
You: Refactor the payment module to use the new service interface.

Copilot (reads copilot-instructions.md):
1. Checks clare/autonomy.yml for src/payment — humans-only
2. Responds: "src/payment is marked humans-only in autonomy.yml. 
   I won't generate code there. Please make this change yourself, 
   or update the autonomy boundary if it's changed."
```

### For debugging

```
You: Why is my architecture test failing?

Copilot: Runs ./clare/verify-ci.sh --fast, reads output, diagnoses failure.
```

---

## Adding Skill Files for Your Project

Skill files are instruction files that activate for specific patterns. Place them in `.github/instructions/`:

```bash
# Examples of project-specific skills:
.github/instructions/type-sync.instructions.md      # applyTo: backend/models/**
.github/instructions/proto-gen.instructions.md      # applyTo: proto/**
.github/instructions/db-migrations.instructions.md  # applyTo: migrations/**
```

Copy the content from `clare/templates/skills/` and add the `applyTo` frontmatter:

```markdown
---
applyTo: "backend/models/api/**"
---
# [Contents of clare/examples/skills/type-sync.md]
```

---

## Troubleshooting

**Copilot ignores my instructions:**
- Check that `github.copilot.chat.codeGeneration.useInstructionFiles` is `true`
- Verify the frontmatter `applyTo` pattern matches your file (test with `**` for all files)
- Open `.github/copilot-instructions.md` and ask Copilot "What instructions do you have for this project?"

**Copilot doesn't check autonomy.yml:**
- The AI checks autonomy.yml based on instructions, not mechanically. Try: "Before modifying any file, tell me its autonomy level from clare/autonomy.yml"
- The architecture test in `autonomy-guard.test.js` provides mechanical enforcement

**verify-ci.sh not found:**
- Run `chmod +x clare/verify-ci.sh && chmod +x scripts/clare-installer.sh`
- Make sure you're running from the project root

**VS Code task "CLARE: Verify CI" doesn't appear:**
- Check `.vscode/tasks.json` exists in your project
- Try reloading the window: `Ctrl/Cmd + Shift + P` → "Reload Window"
