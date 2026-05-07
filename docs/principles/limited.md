# [L] Limited — Define Where AI Works Alone vs With Humans

> Not all code is equal. Some is strategic and costly to get wrong. Some is boilerplate and instantly regeneratable. Treat them the same and you'll over-review the trivial and under-review the critical.

---

## The Problem

By default, your AI tools treat all code the same. That means:

- It will happily modify your payment processing logic as freely as it modifies CSS
- It will regenerate your core domain models without realizing they encode years of business decisions
- Code review has no signal about which AI changes are risky vs routine

The solution: **make boundaries explicit and machine-readable**.

---

## The Three Levels

### `full-autonomy`

AI can read, write, and regenerate freely. No restrictions. No review reminders.

**When to use:**
- Code fully derived from a source of truth (generated TypeScript types, proto components)
- Pure utility functions with 100% test coverage
- Test fixtures and mock data
- Documentation generated from code

**Why it's safe:** Either the code is always regeneratable from a source of truth (so mistakes are easily corrected), or it has high test coverage that would catch wrong behavior.

### `supervised`

AI generates code, but the human reviews before committing. AI adds a reminder to its response.

**When to use:**
- Business logic implementations
- API endpoint handlers
- Database query layers
- UI components with business rules embedded
- Database migrations (irreversible!)

**Why it matters:** The code may be correct but could subtly violate business rules that aren't captured in tests. Human review catches semantic errors that tests don't.

### `humans-only`

AI must not generate code in this path. When instructed to do so, it refuses and explains.

**When to use:**
- Core domain models (strategic work, not code generation)
- Payment and billing logic
- Authentication and authorization core
- Cryptographic implementations
- Regulatory compliance code

**Why it matters:** Mistakes here have severe consequences — financial, security, or legal. The cost of a subtle AI error far exceeds the time saved by generating the code.

---

## The autonomy.yml Format

```yaml
# clare/autonomy.yml

project: "my-project"

modules:
  - path: "src/generated"
    level: full-autonomy
    reason: "Generated from protobuf — always regeneratable"

  - path: "src/utils"
    level: full-autonomy
    reason: "Pure functions, 100% test coverage, no side effects"

  - path: "src/api"
    level: supervised
    reason: "Business rules embedded; may have subtle semantic errors"

  - path: "src/payment"
    level: humans-only
    reason: "Money movement; AI errors are financial risk"

  - path: "*"
    level: supervised    # Default for uncategorized paths
    reason: "Default: untagged paths require human review"
```

**Path matching:** Most specific rule wins (longest prefix). The `*` default applies when nothing more specific matches.

---

## Enforcing the Boundaries

### AI enforcement (immediate)

The AI tools in this project are configured to check `clare/autonomy.yml` before every file change. This is the primary enforcement mechanism.

- **Copilot:** `.github/copilot-instructions.md` instructs it to check autonomy.yml
- **Claude:** `CLAUDE.md` and `.claude/commands/check-autonomy.md` provide explicit instructions
- **Cursor:** `.cursor/rules/clare-limited.mdc` with `alwaysApply: true`

### Architecture test enforcement (CI)

The autonomy guard test in `clare/templates/architecture-tests/autonomy-guard.test.js` reads `autonomy.yml` and checks staged files against it:

```bash
# Add to clare/verify-local.sh:
run_check "Autonomy guard" "cd '$PROJECT_ROOT' && npx jest tests/architecture/autonomy-guard.test.js 2>&1"
```

This catches cases where AI might slip a change past the AI-level guard.

### Pre-commit hook (optional, strongest enforcement)

```bash
# .husky/pre-commit
npx jest tests/architecture/autonomy-guard.test.js --passWithNoTests
```

With this in place, the CI will prevent committing changes to humans-only paths regardless of how the change was made.

---

## Calibrating Your Boundaries

**Start conservative:** If you're unsure, use `supervised`. You can relax to `full-autonomy` later when you have confidence.

**Review quarterly:** As your test coverage grows and patterns stabilize, some `supervised` paths may be safe to promote to `full-autonomy`.

**Watch for patterns:**
- If you're frequently overriding a `humans-only` boundary, it may be too restrictive
- If AI changes in `supervised` zones keep sailing through review unchanged, the tests are probably strong enough for `full-autonomy`

---

## Making It Explicit in Code

For self-documenting boundaries, add comments to key files:

```typescript
// src/domain/user.ts
// autonomy: humans-only
// This file is in the core domain model. See clare/autonomy.yml.
// Do not modify with AI tools. Update clare/autonomy.yml if this boundary changes.
```

```python
# backend/payment/processor.py
# autonomy: humans-only
# Money movement logic. No AI generation. Reviewed by: @payment-team
```

The autonomy guard architecture test can be extended to check for these comments and cross-reference them with `autonomy.yml`.

---

## Measuring Success

You know [L] is working when:
- AI code reviews have a clear signal: "supervised" vs "full-autonomy" changes
- Humans-only paths have zero AI-generated commits
- Review time drops on full-autonomy zones (you trust the tests)
- The team has a shared vocabulary for discussing code risk
