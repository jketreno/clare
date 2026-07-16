# Roo Code and Zoo Code Setup

Zoo Code is the maintained community successor to Roo Code and retains Roo's
`.roo/` project configuration layout. CLARE installs root `AGENTS.md`,
`.roo/rules/`, `.roo/commands/`, and selected `.roo/skills/` packages.

Roo issue #11504 requested pre-tool, post-tool, and stop hooks but remained open
when Roo was archived. Zoo currently documents no repository hook format like
`.github/hooks/*.json`. CLARE's `.roo/rules/clare.md` therefore emits equivalent
normalized CLARE2 lifecycle events from agent instructions. These events are
prompt-enforced, not deterministic extension hooks.

No `.roo/hooks.json` is installed because it is not a supported configuration
surface. See the repository's `docs/ai-tools/roo-zoo.md` for verification and
current upstream references.
