# [C] Constrained — Make Rules Enforced, Not Suggested

> If a rule only exists in a code review comment, it will be violated by AI.
> Architecture rules must live in tools that catch violations automatically.

---

## The Problem

You have a code review comment you write every sprint. The AI generates code. It violates the rule. You write the comment again. Loop forever.

AI cannot read your mind. Rules that exist only in people's heads — or even in documentation — are invisible to AI tools.

The solution: **make the rule fail the build**.

---

## The Mechanism: verify-ci.sh

Everything flows through `clare/verify-ci.sh`. AI tools are instructed to run it after every code change. If it fails, they fix the issue and run again. The work is not complete until it passes.

This creates a local feedback loop that catches issues in seconds rather than waiting for CI/CD (minutes) or code review (hours/days).

---

## Levels of Enforcement

### Level 1: Linter Rules

The fastest enforcement. No new files needed — just configuration.

**Example: Stop console.log in production**

```javascript
// eslint.config.js
export default [
  {
    rules: {
      'no-console': 'error',
      'no-debugger': 'error',
    }
  }
];
```

Now `verify-ci.sh` runs ESLint → catches console.log → AI sees the failure → AI removes it → reruns → passes → done. You never see it.

**Example: Enforce import boundaries**

```javascript
// eslint.config.js
export default [
  {
    rules: {
      'no-restricted-imports': ['error', {
        patterns: [
          {
            group: ['../payment/*'],
            message: 'Import payment logic through the service layer only'
          }
        ]
      }]
    }
  }
];
```

See `clare/templates/linting/` for more complete ESLint configurations.

### Level 2: Type System

TypeScript catches entire categories of errors at compile time. Make type errors → build failures.

```bash
# In verify-ci.sh — zero tolerance for type errors
run_check "TypeScript" "npx tsc --noEmit --strict 2>&1"
```

Use the type system to enforce domain constraints:

```typescript
// Use branded types to prevent mixing IDs
type UserId = string & { __brand: 'UserId' };
type OrderId = string & { __brand: 'OrderId' };

// Now this is a compile error:
function getOrder(id: UserId): Order { ... } // TypeScript won't accept an OrderId here
```

### Level 3: Architecture Tests

For rules that can't be expressed in a linter or type system. These are tests that check structural properties of your codebase, not behavior.

**Pattern: All endpoints have rate limiting**

```javascript
// tests/architecture/api-rules.test.js
test('all API endpoints have rate limiting', () => {
  const endpoints = loadApiEndpoints(); // scan your route files
  const missing = endpoints.filter(ep => !hasRateLimiting(ep));
  
  if (missing.length > 0) {
    throw new Error(`Missing rate limiting:\n${missing.map(ep => `  ${ep.file}`).join('\n')}`);
  }
});
```

**Pattern: No cross-boundary imports**

```javascript
// tests/architecture/module-boundaries.test.js
test('utility code does not import from business logic', () => {
  const utilFiles = getAllFiles('src/utils');
  const violations = [];
  
  for (const file of utilFiles) {
    const imports = extractImports(file);
    for (const imp of imports) {
      if (imp.includes('src/services') || imp.includes('src/domain')) {
        violations.push(`${file} imports from ${imp}`);
      }
    }
  }
  
  expect(violations).toHaveLength(0);
});
```

See `clare/templates/architecture-tests/` for generic tests and `clare/examples/architecture-tests/` for domain-specific examples.

---

## Wiring It All Together

### Enforcement Decision Tree

Use this quick decision order when adding a new rule:

1. Can the rule be enforced by syntax/import/style checks?
  - Yes -> implement a linter rule first (fastest feedback).
2. If not, can the rule be represented as a type constraint?
  - Yes -> enforce with TypeScript types and `tsc --noEmit`.
3. If not, does it require repository-wide structural analysis?
  - Yes -> add an architecture test.
4. If none of the above fully enforce it:
  - Combine levels (for example, lint + architecture test) and keep the invariant explicit.

**Step 1:** Identify the rule you want to enforce  
("All API responses must include a `requestId`")

**Step 2:** Choose the right enforcement level:
- Linter: syntax/style rules, import rules
- TypeScript: type-level constraints
- Architecture test: structural rules that need code analysis

**Step 3:** Write the enforcement

**Step 4:** Add it to `clare/verify-local.sh`:
```bash
run_check "Request ID enforcement" "cd '$PROJECT_ROOT' && npx jest tests/architecture/request-id.test.js 2>&1"
```

**Step 5:** Tell your AI:
```
This rule is now in clare/verify-local.sh. It will fail if you violate it.
You must run ./clare/verify-ci.sh and pass it before marking work complete.
```

The AI will now catch and fix its own violations before you see the code.

### End-to-End Example: "All API responses include requestId"

> **Note:** The snippets below are illustrative — they show the *shape* of each
> enforcement layer, not production-ready code. Adapt the patterns to your
> stack and tooling.

Linter layer (prevent bypassing shared response helper):

```javascript
// eslint.config.js
export default [
  {
    rules: {
      'no-restricted-imports': ['error', {
        patterns: [
          {
            group: ['../raw-response/*'],
            message: 'Use the shared response helper that injects requestId'
          }
        ]
      }]
    }
  }
];
```

Type layer (response contract requires requestId):

```typescript
type ApiResponse<T> = {
  requestId: string;
  data: T;
};

function ok<T>(requestId: string, data: T): ApiResponse<T> {
  return { requestId, data };
}
```

Architecture test layer (all handlers must return requestId):

```javascript
// tests/architecture/request-id.test.js
test('all API handlers include requestId in response payload', () => {
  const handlers = loadApiHandlers();
  const violations = handlers.filter((h) => !handlerIncludesRequestId(h));
  expect(violations).toHaveLength(0);
});
```

This stack gives fast feedback (lint), compile-time guarantees (types), and a structural backstop (architecture test).

---

## Using AI to Build Constraints

The powerful move: **use AI to write the constraints**. Then you review and approve.

```
"Write me an architecture test that verifies all API endpoints have:
 1. Rate limiting
 2. Input validation with a schema
 3. Authentication required
 
 Then add it to clare/verify-local.sh.
 Use clare/examples/architecture-tests/api-rules.test.js as a starting point."
```

AI generates the constraint. You review it (10 minutes). Now the constraint enforces itself on all future AI-generated code.

---

## Common Rules to Enforce

| Rule | Enforcement |
|------|-------------|
| No console.log in production | ESLint `no-console` |
| No unused imports | ESLint `no-unused-vars` / TypeScript |
| All endpoints have rate limiting | Architecture test |
| No cross-domain imports | ESLint `no-restricted-imports` |
| All public functions have types | TypeScript strict mode |
| All tests use invariants not confirmations | Test framework (harder — rely on code review for this one) |
| Generated files not hand-edited | Architecture test: check for @generated header drift |

---

## Measuring Success

You know [C] is working when:
- Code review comments drop in frequency
- AI-generated PRs arrive already passing your local checks
- "I forgot to add X" stops being a PR comment
- New team members never violate rules you haven't told them about
