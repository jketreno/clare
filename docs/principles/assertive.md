# [A] Assertive — Write Tests That Define What Must Always Be True

> Confirmation tests tell you what the code does today. Constraint tests tell you what it must always do, regardless of how it's implemented. Only one of those protects you when AI regenerates your code.

---

## The Problem

You have tests. AI generates code. Tests pass. You ship.

But the tests were confirmation tests — they verified the old implementation. When AI generates a new implementation, the tests pass because they were written to match the old behavior, not to enforce invariants. The new implementation could be subtly wrong in ways the tests don't catch.

The solution: **describe what must always be true, not what the current implementation does**.

---

## Confirmation vs. Constraint

| | Confirmation Test | Constraint Test |
|--|--|--|
| **Describes** | Current implementation | Business invariant |
| **Breaks when** | Implementation changes | Invariant is violated |
| **Survives regeneration** | Sometimes | Yes (if the invariant is met) |
| **Catches bugs** | Only the bug it was written for | Any violation of the rule |
| **Example** | `expect(getUser(1).email).toBe('a@b.com')` | `expect(() => createUser(email)).not.toThrow()` |

---

## Writing Constraint Tests

### Technique 1: Name tests as invariants

Use the pattern: `[subject] [never/always/must/cannot] [condition]`

```typescript
// ❌ Confirmation
test('returns a user', () => {
  expect(getUser(1)).toBeDefined();
});

// ✅ Constraint
test('always returns a user for any existing ID', () => {
  seedUser({ id: 1 });
  expect(getUser(1)).toBeDefined();
});

test('never returns a user for an ID that was never created', () => {
  expect(getUser(99999)).toBeNull();
});
```

### Technique 2: Property-based testing

Generate hundreds of random inputs and verify your invariant holds for all of them.

```typescript
import fc from 'fast-check';

// Invariant: email normalization is idempotent
test('normalizeEmail is idempotent', () => {
  fc.assert(
    fc.property(fc.emailAddress(), (email) => {
      expect(normalizeEmail(normalizeEmail(email))).toBe(normalizeEmail(email));
    })
  );
});

// Invariant: balance never goes negative
test('deduct never creates a negative balance', () => {
  fc.assert(
    fc.property(
      fc.integer({ min: 0, max: 1_000_000 }),
      fc.integer({ min: 0, max: 1_000_000 }),
      (balance, amount) => {
        fc.pre(amount <= balance); // Precondition
        const result = deduct(balance, amount);
        expect(result).toBeGreaterThanOrEqual(0);
      }
    )
  );
});
```

**Python equivalent with Hypothesis:**

```python
from hypothesis import given, strategies as st, assume

@given(
    balance=st.integers(min_value=0, max_value=1_000_000),
    amount=st.integers(min_value=0, max_value=1_000_000)
)
def test_deduct_never_creates_negative_balance(balance, amount):
    assume(amount <= balance)
    result = deduct(balance, amount)
    assert result >= 0
```

### Technique 3: Schema-lock tests

For any external API contract or event schema, add a snapshot that would fail if the schema changes unexpectedly:

```typescript
import { UserSchema } from '../types/api/user';

test('User API response schema matches declared type', () => {
  const response = {
    userId: 'usr_123',
    email: 'a@b.com',
    displayName: 'Alice',
    subscriptionStatus: 'premium',
    createdAt: '2024-01-01T00:00:00Z',
  };
  
  // This fails if the Zod schema and the actual API shape diverge
  const result = UserSchema.safeParse(response);
  expect(result.success).toBe(true);
});
```

### Technique 4: Invariant extraction from team knowledge

Listen for these phrases in PR comments and team discussions. They are invariants waiting to be tests:

- "this should never happen" → negative test
- "we always guarantee..." → positive constraint test
- "this assumes that..." → precondition test
- "if X then always Y" → property-based test
- "these two things must always be equal" → parity test

---

## Architecture Tests as Constraints

Architecture tests are constraint tests at the structural level:

```javascript
// Invariant: every API endpoint has rate limiting
test('all endpoints have rate limiting', () => {
  const endpoints = loadEndpoints();
  const missing = endpoints.filter(ep => !ep.hasRateLimiting);
  expect(missing).toHaveLength(0); // Always zero — no exceptions
});

// Invariant: supervised code never directly imports from humans-only paths
test('supervised modules do not import from humans-only modules', () => {
  const violations = findBoundaryViolations();
  expect(violations).toHaveLength(0);
});
```

These run in `verify-ci.sh` and enforce structural invariants that linters and type systems can't catch.

---

## The Test-the-Test Exercise

Once you have tests, do this exercise for your most critical modules:

1. **Delete** the implementation (keep the tests)
2. Ask AI to **regenerate** it: "Write an implementation that makes these tests pass"
3. **Run** the tests

**Interpreting the results:**

- Tests **fail** → Your tests are enforcing real invariants. The AI produced a different (potentially valid) implementation that violates something. This is tests working correctly.

- Tests **pass** → Two possibilities:
  - ✅ Your constraints are complete — any correct implementation satisfies them
  - ⚠️ Your tests are too weak — validate that the regenerated implementation is actually correct

The exercise reveals where your test coverage is incomplete. It's uncomfortable but valuable.

---

## Test Coverage vs. Constraint Coverage

High line coverage does not mean strong constraints. You can have 100% coverage with 100% confirmation tests.

A better metric: **regeneration stability**. After regenerating an implementation with AI, how many tests fail?

- Many failures = strong constraints (good — they caught real differences)
- Zero failures (and implementation is correct) = constraints are complete
- Zero failures (but implementation is wrong) = constraints need strengthening

---

## Practical Adoption Path

**Week 1:** Convert your 3 most important existing tests to use invariant naming. No other changes.

**Week 2:** Add one property-based test to your most critical module.

**Week 3:** Add one architecture test from `clare/templates/architecture-tests/` to `verify-local.sh`.

**Week 4:** Extract invariants from your last 5 code review comments. Write tests for them.

---

## Tools

| Language | Property-Based Testing | Architecture Testing |
|----------|----------------------|---------------------|
| TypeScript/JS | `fast-check` | Jest + custom matchers |
| Python | `hypothesis` | pytest + custom fixtures |
| Go | `gopter`, `rapid` | testify + custom checks |
| Rust | `proptest` | integration tests |

---

## Measuring Success

You know [A] is working when:
- Deleting and regenerating a module produces code that passes existing tests
- AI-generated PRs have tests that would catch wrong implementations, not just the current one
- "I didn't know that rule existed" stops being a post-incident finding
- Code review shifts from "did the tests pass" to "do the tests enforce the right invariants"
