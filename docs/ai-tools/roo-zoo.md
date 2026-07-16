# Roo Code and Zoo Code Setup Guide

Zoo Code is the maintained community successor to the archived Roo Code
project. Zoo documents compatibility with Roo's settings and continues to use
the `.roo/` project directory.

CLARE installs these supported surfaces:

- `AGENTS.md`, loaded by Roo/Zoo by default
- `.roo/rules/clare.md`, loaded in every mode
- `.roo/commands/*.md` for project slash commands
- `.roo/skills/<name>/SKILL.md` for selected Agent Skills
- `.roo/mcp.json` when a project registers a CLARE MCP server

## Lifecycle capture limitation

Roo issue #11504 requested hooks for pre-tool, post-tool, and stop events; it
remained open when the Roo repository was archived. Zoo's current documentation
does not define a repository hook format comparable to `.github/hooks/*.json`.
CLARE therefore installs prompt-level lifecycle instructions in
`.roo/rules/clare.md`. They emit the same normalized CLARE2 event names through
`clare2-capture-event.sh`, but they are agent-enforced rather than deterministic
extension hooks.

Run `./clare/scripts/clare2-install-hooks.sh` to repair deterministic hooks for
providers that support them. No `.roo/hooks.json` is created because that is not
a documented Roo/Zoo configuration surface.

## Verify

1. Open the repository in Roo or Zoo Code.
2. Ask which autonomy level applies to a path; the response should cite
   `clare/autonomy.yml`.
3. Select an installed skill and confirm its `SKILL.md` is discovered.
4. Submit a harmless task and check the configured CLARE2 corpus for `zoo`
   interaction records.
