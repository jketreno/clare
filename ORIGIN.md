# Your Architecture is Breaking Down and AI is Making It Worse

I spent decades at Intel working across the entire vertical stack of compute—from kernel to web to cloud, and all points in between, to AI models, training, inference, and coding assistance. I left in the fall of 2024 and took a year diving deep into AI, talking with companies that were all struggling with the same thing: how to actually apply AI in their work without breaking everything they'd built. In my current job, I'm still seeing it. Same patterns. Same problems.

Here's what I'm seeing across teams:

You've spent years building up good design practices. Your team knows the patterns. Everyone understands how things should be structured. Code reviews enforce the standards you've fought to establish.

Then you add Cursor, Copilot, Claude, or Codex to the mix, and suddenly you're generating code at 10x speed. Which sounds great until you realize the AI is creating technical debt faster than you can review it. Code that works but doesn't fit your patterns. Implementations that pass tests but violate the principles your team has relied on for years. Changes that would have taken weeks of mentoring a junior dev to understand are now happening in every AI-generated PR.

The problem isn't the AI. The problem is your architecture rules exist in people's heads and code review comments. LLMs can't read your mind.

## What Actually Works: CLARE

I've been looking at how teams are handling this. There's a pattern emerging that makes sense. I'm calling it **CLARE (Constrained, Limited, Assertive, Reality-Aligned, Ephemeral)** (the acronym itself was AI-generated from my tenets — a fitting origin for a framework about constraint-driven generation):

- **C**onstrained - Make your rules enforced, not suggested
- **L**imited - Define where AI can work alone vs where you need humans  
- **A**ssertive - Write tests that define what must always be true
- **R**eality-Aligned - Your domain model must match actual business reality
- **E**phemeral - Stop editing code you or AI could regenerate

Let me break down what each of these means in practice:

### **[C] Constrained** - Make Your Rules Enforced, Not Suggested

This is the same thing we've been doing with linters for years with human developers. If you don't want people committing code with warnings, you don't just write it in code review—you make the build fail.

Simple example: Instead of catching this in review:
```
❌ Code Review: "Don't commit code with compiler warnings"
```

Do this in your CI/CD:
```yaml
# .github/workflows/ci.yml
- name: Build and check warnings
  run: |
    npm run build -- --strict
    if [ $? -ne 0 ]; then
      echo "Build has warnings - fix before merging"
      exit 1
    fi
```

But here's the key with AI--don't wait for CI/CD to catch this. Make the AI verify these checks pass BEFORE it finishes generating code.

Set up local verification that mirrors your CI/CD:
```bash
# scripts/verify-ci.sh
#!/bin/bash
# Run the same checks CI/CD will run

echo "Running build checks..."
npm run build -- --strict || exit 1

echo "Running linter..."
npm run lint || exit 1

echo "Running tests..."
npm test || exit 1

echo "Running architecture tests..."
npm run test:architecture || exit 1

echo "✅ All CI/CD checks passed locally"
```

Then add this to your AI's workflow:
```markdown
Before marking any work as complete:

1. Run ./scripts/verify-ci.sh
2. If it fails, fix the issues and run again
3. Only when all checks pass, consider the work done
4. Remind the user to commit

Never tell me "the work is complete" if verify-ci.sh fails.
```

**The workflow with AI:**
- You: "Add a new User endpoint"
- AI generates the code
- AI automatically runs `./scripts/verify-ci.sh`
- If it fails: AI sees the errors, fixes them, runs again
- Only when it passes: "Endpoint complete, all CI/CD checks pass"

Now the AI can't finish code that won't pass CI/CD. The build fails locally before you even commit. Same checks, faster feedback, no wasted CI/CD cycles.

This is way more efficient than pushing code and waiting for the pipeline to fail. The AI catches and fixes issues in seconds instead of minutes.

**"But I can't run tests locally without our staging infrastructure..."**

Stop. Define your external dependencies as API contracts. Mock infrastructure is ephemeral - it's regeneratable from the contract. Tell the AI: "Build me mocks based on these API contracts" and point it at your OpenAPI specs or proto definitions. Now your tests run locally. No excuses. The AI generates the mocks, you verify they match the contracts, verify-ci.sh runs with mocks. When you push, integration tests run against real infrastructure. You've eliminated the "can't test locally" excuse.

More complex example that's still straightforward:

Your code reviews keep saying "don't use console.log in production code" but AI keeps adding them for debugging. Instead of reviewing every file:

```javascript
// .eslintrc.js
module.exports = {
  rules: {
    'no-console': 'error'  // Build fails if console.log exists
  }
}
```

AI generates code with console.log → runs verify-ci.sh → linter fails → AI removes console.log → runs verify-ci.sh again → passes → marks work complete.

You never see the code with console.log in it. The AI caught and fixed it before showing you.

Take it further - your team has a rule "all API endpoints need rate limiting." Stop catching this in review!

```javascript
// pseudo code tests/architecture/api-rules.test.js
describe('API Architecture Rules', () => {
  test('all endpoints have rate limiting', () => {
    const endpoints = getAllApiEndpoints();
    endpoints.forEach(endpoint => {
      expect(endpoint).toHaveRateLimiting();
    });
  });
});
```

Now when AI generates a new endpoint:
1. Generates endpoint code
2. Runs `npm run test:architecture`
3. Test fails - no rate limiting
4. AI adds rate limiting
5. Runs tests again
6. Tests pass
7. "Endpoint complete with rate limiting"

Your architecture rule is enforced before the code leaves the AI's context, not by humans remembering to check, not even by waiting for CI/CD.

Here's the part people miss: **use AI to build these constraints AND the verification scripts**. Tell your agent "write me a test that verifies all API endpoints have rate limiting, and add it to the verify script" - it'll generate both. You review it, tweak it, run it. Now you've got a constraint that took 10 minutes instead of an afternoon, and it runs automatically before every commit.

### **[L] Limited** - Figure Out Where AI Can Work Alone vs Where You Need Humans

Not every module needs the same oversight. Your billing service with 95% test coverage and clear boundaries? Let the AI maintain it. Your payment processing with money movement and regulations? Keep humans in the loop.

Make this explicit. Tag your modules. Tell your team and your AI tools which areas are "full autonomy" vs "supervised" vs "humans only."

The concept looks like this:

```yaml
# Conceptual example - showing the idea, not the implementation

Full Autonomy (AI can modify freely):
- API client wrappers
- Data transformation utilities
- Test fixtures
- Proto visualization components

Supervised (AI generates, human reviews):
- Business logic implementation
- Database migrations
- API endpoint handlers

Humans Only (no AI generation):
- Core domain models
- Payment processing logic
- Security-critical code
```

But how do you actually enforce this? You can't just write it in a YAML file and hope the AI reads it. You need it embedded in your workflow, your tools, and your constraints.

For a working implementation of autonomy boundaries that's actually enforced through tooling and AI instructions, check out the CLARE bootstrap project at https://github.com/jketreno/clare. It shows how to make these boundaries machine-readable and enforceable rather than just documentation.

There's a second-order benefit here that teams miss until they've lived it: **the autonomy label is a signal to every other human on the team, not just the AI.**

When a PR lands and the diff is entirely in full-autonomy modules, your senior engineers don't need to deep-read it. If verify-ci.sh passes, the constraints are your review. The label tells you: "this code was allowed to change freely, and it passed everything that matters."

Compare that to today: a `git diff` doesn't tell you whether you're looking at throwaway glue code or critical business logic. Everything looks equally important. So you review everything equally — which means senior engineers are spending the same mental energy on a generated API wrapper as they are on a payment flow change.

Explicit autonomy boundaries change that. A diff through full-autonomy code gets a different kind of attention than a diff through humans-only code. That's not lowering your standards. That's applying them correctly.

### **[A] Assertive** - Write Tests That Define What Must Always Be True

Here's where generated-code rules and Assertive tests work together. You need tests that guarantee Python and TypeScript types stay compatible.

Use PLAN mode to design the test framework with AI:

**Me:** "I need a test framework that guarantees my Python Pydantic models and TypeScript interfaces stay in sync. Show me the plan."

**AI in PLAN mode:**
```
Plan for Type Compatibility Test Framework:

1. Python side tests (pytest):
   - Load all Pydantic models from backend/models/api/
   - Generate JSON schema from each model
   - Compare against corresponding TS interface structure
   - Verify field types match (str → string, int → number, etc.)
   - Verify required fields match
   - Verify validation rules match Zod schemas

2. TypeScript side tests (jest):
   - Load all TS interfaces from src/types/api/
   - Verify corresponding Zod schema exists
   - Test Zod schema against sample data
   - Verify Zod validation matches Pydantic validation

3. Integration test:
   - Generate sample data from Pydantic model
   - Serialize to JSON
   - Parse with TypeScript and validate with Zod
   - Should pass without errors

Would you like me to implement this?
```

**Me:** "Yes, and make it fail loudly if types drift."

...and the AI generates the test framework.

Now you review it--if the tests aren't good, AI won't be constrained. Most teams think they have good tests, but many are only confirmation tests. They verify what the code does today, not what must always be true. What you want are **constraint tests**. What do I mean?

**Weak vs strong:**

```ts
// ❌ Weak test: only confirms implementation
it('creates a user', () => {
  const user = createUser("test@test.com");
  expect(user.email).toBe("test@test.com");
});
```

```ts
// ✅ Strong test: enforces a rule that must always hold
it('never creates duplicate users for the same email', () => {
  fc.assert(
    fc.property(fc.emailAddress(), email => {
      createUser(email);
      expect(() => createUser(email)).toThrow();
    })
  );
});
```

Provide feedback to the AI's implementation; focus it to create tests capturing the intent, not the implementation.

**Test the test**

1. Delete the implementation.
2. Re-generate with AI.
3. Observe the outcome:

> If your tests fail after regenerating the implementation, they are doing their job.  
> If your tests pass, either:
>
> - your tests fully capture what must be true (**success!**), or
> - they are too weak to catch subtle violations (**warning!**).

That distinction matters. Passing tests after regeneration is not automatically proof of bad tests. It may mean your tests and definitions are strong enough that the AI can reliably recreate the implementation. That's the goal. But most teams should treat a clean pass as something to validate, not assume.

- Extract rules from PR comments or team knowledge.
- Look for phrases like:
  - "this should never happen"
  - "we always guarantee..."
  - "this assumes..."
- Turn those into tests.
- Add one or two high-value property-based tests per critical module.
- Add a snapshot or schema-lock test for important contracts.
- Periodically delete and regenerate non-critical implementations to validate that your constraints are real.
 
One brutal but valuable exercise: delete a non-trivial component, keep only the tests and contracts, then regenerate it with AI. If it comes back correct, you've defined the system well. If it doesn't, you now know exactly where the ambiguity lives.

Once you know you have a good testing framework defined, the workflow becomes:

1. You update the Python User model, add a `phone_number` field
2. You ask AI to regenerate TypeScript types (following Ephemeral rules)
3. AI runs `./scripts/verify-ci.sh` which includes these compatibility tests
4. If TypeScript types weren't regenerated correctly, tests FAIL immediately:
   ```
   ❌ Field phone_number in User missing in TypeScript
   ```
5. AI sees the failure, regenerates TypeScript types correctly
6. Runs verify-ci.sh again
7. Tests pass
8. "User model updated with phone_number, TypeScript types synchronized"

Now your review becomes: "Did the AI's final run pass all checks?" Not "Did you remember to update all three places where types need to match?"

Way faster. Way more confident.

The test framework took 20 minutes to set up with PLAN mode. Every subsequent type change is verified automatically before the AI marks work complete. When the AI adds a field and the types drift, it catches and fixes it itself before you ever see it.

### **[R] Reality-Aligned** - Your Domain Model Must Match Business Reality

This is the one people miss. If your understanding of how the system should work doesn't precisely match reality, the AI generates mountains of plausible-but-wrong code.

Clear model of how things work: AI generates correct implementations across your whole system.
Fuzzy model: AI generates convincing code that doesn't match how your business actually works.

Invest in understanding and documenting how things actually work. It pays back 10x with AI in the loop. Many systems do not actually have a single source of truth. They have:

- one version in the database
- another in the API
- another in the frontend
- another in an external billing or auth system
- and a fifth version living in someone's head

When that happens, AI picks one--sometimes the wrong one.

**Actionable steps:**

1. Pick one domain concept such as `User`, `Device`, or `ServiceConfig`.
2. Identify the real source of truth:
   - database schema
   - protobuf/OpenAPI contract
   - identity provider or IAM system
   - configuration management database
   - whatever system actually decides reality
3. Make everything else derive from it.
4. Tell the AI explicitly what wins when systems disagree.

For example:

```text
The source of truth for user permissions is the identity provider.
If local code disagrees, the IdP is correct.
```

Then write **reality tests** to verify alignment:

```ts
it('matches identity provider permission state', async () => {
  const idpPerms = await idp.users.getPermissions(userId);
  const local = await getPermissions(userId);

  expect(normalize(local)).toEqual(normalize(idpPerms));
});
```

Run these in staging or nightly. They don't need to run on every PR. The goal is to catch drift between your implementation and the real world before that drift becomes the new normal.

A simple exercise that reveals a lot--pick one domain concept and answer three questions:

- Where is it defined?
- Where is it validated?
- Where is it actually enforced?

If those answers point to different places, you have drift.

### **[E] Ephemeral** - Stop Editing Generated Code You or AI Could Regenerate

Here's the workflow that's working: Set up your boundaries once using skills and rules files at the repository level. Then leverage AI to create all the boilerplate that adheres to those boundaries.

Example - keeping Python backend and TypeScript frontend types in sync:

```markdown
When defining shared data structures:

Backend (Python):
- Use Pydantic v2 models with Field() for validation
- CamelCase for class names, snake_case for fields
- Include model_config with json_schema_extra for TS mapping
- Add docstrings that will become TS comments

Frontend (TypeScript):
- Generate matching TS interfaces in src/types/api/
- Use camelCase for property names (snake_case → camelCase conversion)
- Include the same validation rules as Zod schemas
- Preserve comments from Python docstrings

Example mapping:
Python: user_id: str = Field(min_length=1)
TypeScript: userId: string  // + Zod: z.string().min(1)

All shared types must be defined in backend/models/api/
and have corresponding generated TS in frontend/src/types/api/

When I update a Python model, remind me to regenerate the TS types.
```

Now when I say "create a User model with email and subscription status", the agent generates:

Backend:
```python
class User(BaseModel):
    """User account information"""
    user_id: str = Field(min_length=1, description="Unique user identifier")
    email: EmailStr = Field(description="User email address")
    subscription_status: Literal["free", "premium", "enterprise"]
    
    model_config = ConfigDict(json_schema_extra={"ts_interface": "User"})
```

Frontend:
```typescript
/** User account information */
export interface User {
  /** Unique user identifier */
  userId: string;
  /** User email address */
  email: string;
  subscriptionStatus: "free" | "premium" | "enterprise";
}

export const UserSchema = z.object({
  userId: z.string().min(1),
  email: z.string().email(),
  subscriptionStatus: z.enum(["free", "premium", "enterprise"]),
});
```

The first time you write the rules file takes work. Every subsequent model follows those rules automatically. When you add a field to User in Python, you ask AI to regenerate the TypeScript types - it reads the rules and keeps everything in sync.

The AI isn't running a build script - it's reading your constraints and generating code that respects them across both languages. That's way more powerful than traditional code generation because the AI understands the meaning, not just the syntax.

## CLARE in Practice: Real Example

Let me show you all five CLARE principles working together on a real project:

We had a collection of protobuf APIs that were constantly evolving - new APIs added, models tweaked, parameters adjusted. We needed a utility to validate the latest version of the APIs, see what the services were returning, and visualize them in a way that made testing easy.

**Old way:**
- Manual review of API changes in the protobuf definitions
- Manual implementation of UI components to match
- Manual test building for each new field or endpoint
- Days or weeks per iteration

**New way with CLARE:**

**[C] Constrained** - Define the boundary:
```
"React UX component that visualizes protobuf responses, 
TypeScript with no warnings, full test coverage"
```

**[E] Ephemeral** - Create the skill file:

```markdown
When user says "update the protos":

1. Check for new protobuf versions in the API repository
2. Examine the diff between current and new versions
3. Implement new gaps:
   - New messages → new TypeScript interfaces + React components
   - New fields → add to existing components with proper typing
4. Delete deprecated:
   - Remove components for deleted messages
   - Remove fields from interfaces
5. Modify for any deltas:
   - Type changes → update TS interfaces + validation
   - Field renames → update throughout component tree

All generated code must:
- Use TypeScript with strict mode (zero warnings)
- Include full test coverage for new/modified components
- Follow the existing component structure in src/components/proto/
- Generate Zod schemas matching the protobuf definitions

Before marking complete:
- Run ./scripts/verify-ci.sh
- Only report completion when all checks pass
```

**[L] Limited** - Mark the autonomy level:
```yaml
# Proto visualization module: FULL AUTONOMY
# Reason: Derived from source of truth (the protobufs)
# All components are regeneratable
```

**[A] Assertive** - Tests enforce the contract:
```typescript
describe('Proto UI Components', () => {
  test('all proto messages have corresponding components', () => {
    const protoMessages = loadProtoDefinitions();
    const components = loadComponentRegistry();
    
    protoMessages.forEach(message => {
      expect(components).toHaveComponentFor(message);
    });
  });
  
  test('component props match proto field types exactly', () => {
    // Property-based test that generates test cases
    // for every field in every message
  });
});
```

**[R] Reality-Aligned** - The protobufs ARE the reality:
```markdown
The protobuf definitions are the source of truth.
The UI must match them exactly.
No manual interpretation. No guessing at types.
Direct mapping: proto field → TS type → React prop → Zod validation
```

**The workflow:**

- Protobufs get updated
- I say: "Implement the latest protobufs"
- AI reads the skill, checks the diff, generates the changes
- AI runs verify-ci.sh automatically
- If tests fail: AI fixes and reruns
- When tests pass: "Proto UI updated, all 47 tests passing"
- 10 minutes later: fully testable Web UI that verifies the entire end-to-end flow

**The leverage:**

First time setting up the skill file and constraints took an afternoon. Every subsequent proto update takes 10 minutes instead of days. When we add a new API with 20 messages, the entire visualization layer gets generated automatically, and I only see it after all tests pass.

And when someone asks "does the UI support the new UserPreferences message?" the answer is always yes, because the constraint won't let the AI finish if it doesn't, and the tests verify it before I even see the code.

## Why This Matters for Different Teams

If you're practicing DDD, Clean Architecture, or SOLID: You've got the principles, but they're not enforced mechanically. Your bounded contexts are getting blurred by AI-generated code. Your dependency rules are in comments, not compilers.

If you don't have a formal methodology: You're probably feeling this even harder. Your "we just know how things should work here" tribal knowledge is completely invisible to AI tools. Every generation is a gamble.

Either way, the solution is the same: **make the implicit explicit and enforceable**. Then use AI to build both the constraints and the code that adheres to them.

## The Integration Problem

There's a methodology called BMad (Breakthrough Method for Agile AI-Driven Development) that's getting traction — it's a structured multi-agent workflow with specialized agents for product management, architecture, development, and QA.

It works. The problem is the agents can still generate code that violates your architecture even while following the workflow perfectly.

That's where CLARE matters. Multi-agent workflows give you process structure. CLARE gives you the architectural guardrails. The same applies to any orchestrated pipeline: Claude Code agents, Codex, Cursor Composer, GitHub Copilot Workspace, LangGraph, CrewAI — the framework doesn't matter. Without enforced constraints, every agent is a potential source of architectural drift.

Together: structured agents that can't break your design rules even if they try.

## How to Actually Start

Don't boil the ocean. Pick one thing this week:

**Option 1 [C]:** Take your most annoying code review comment. The one you write every sprint. Ask AI to turn it into an automated test or linter rule. Add it to a verify script. Tell your AI to run it before marking work complete. Review the test. Run it. Now it's impossible to violate.

**Option 2 [L]:** Pick one low-risk module. Mark it "AI full autonomy." Use PLAN mode to see what AI will generate. Tweak until it matches your patterns. Harden its tests. Let the AI maintain it. Measure what happens.

**Option 3 [E+A]:** Take one critical component. Ask AI to write property-based tests defining what must always be true. Review them. Delete the implementation. Let the AI regenerate it within those constraints. Compare quality.

**Option 4 [R]:** Identify one domain concept. Declare a single source of truth. Write one reality test against it.That's enough to tell whether this is real in your environment.

One experiment. One week. See what actually happens.

Want to see a complete working example? Check out the CLARE bootstrap project at https://github.com/jketreno/clare for templates and implementations of all five principles.

## What I'm Seeing Work

In my own work and across teams I've worked with, the pattern is consistent: once architecture rules are enforced rather than suggested, the majority of infrastructure code becomes safely AI-generated. Well-constrained modules see significant velocity gains — in some cases several times faster than manual implementation. Review time drops dramatically — you're reviewing constraints and tests, not implementations. The autonomy label starts doing work beyond just directing the AI: it signals to every engineer on PR review duty which diffs actually need deep attention. Code entirely in full-autonomy modules with a passing CI run doesn't need the same scrutiny as a change in a humans-only zone. That distinction used to live in someone's head. Now it's in the diff itself.

Architecture drift drops to near zero because the build catches violations before humans ever see them. CI/CD failures become rare — issues are caught and fixed locally by AI before code is ever pushed.

But also: more time spent upfront defining contracts and boundaries. This isn't free. You're trading code review time for architecture definition time.

The difference is the architecture definition compounds. You define a boundary once, it protects you forever. Code review is per-PR, forever.

And with AI helping build the constraints themselves, that upfront time is way less than you think.

## The Counterintuitive Part

**More constraints = more autonomy.**

The tighter you define the boundaries, the more you can safely delegate. Loose boundaries mean you're reviewing everything because anything could break anything.

This feels backwards until you try it.

## What Doesn't Work

Don't do this:
- Treating all code the same (some is precious, some is disposable)
- Letting AI generate your core domain models (that's strategic work)
- Assuming tests written after implementation catch everything
- Trying to adopt everything at once
- Fighting with AI-generated code instead of using AI to build better constraints
- Waiting for CI/CD to catch what AI should verify locally

Start small. One constraint. One boundary. One contract. Use AI to build them. Measure. Expand.

## The Real Question

AI generating 40% of global code isn't a future prediction - it's happening right now. The question isn't whether your team will use these tools.

The question is whether your architecture survives contact with them.

Traditional approaches optimized for humans reading code. CLARE principles optimize for machines generating verifiable code while keeping humans in strategic control.

Your current practices + CLARE guardrails + AI building both = you keep your architecture while gaining velocity.

---

One last thing worth saying: this article was written using CLARE principles. I gave Claude precise constraints (write like James would, based on my own writing samples), clear boundaries (long-form technical article, not marketing copy), and verification criteria (does it sound like me? does every claim match what I actually observed?). I reviewed it, iterated on it, and cut what didn't hold up. The relationship between constraint-giver and generator is exactly what CLARE describes — and it worked here the same way it works in code.

The acronym came from the same process. I gave an LLM my tenets, it gave me CLARE. That's not a confession. That's the point.

What's your most annoying code review comment? That's probably your first constraint. Ask AI to turn it into a test and add it to your verify script.
