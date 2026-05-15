# Changelog

All notable user-facing changes to this project are documented in this file.

## v1.4.1 - 2026-05-15

### Fixed

- **Installer extension setup:** Fixed interactive extension selection so entered choices such as `1 3 4 5` are preserved and enabled instead of being treated as an empty selection.

## v1.4.0 - 2026-05-15

### Added

- **Complexity extension coverage expanded:** Added shellmetrics complexity checks for Bash/Shell and strengthened Go/Python complexity enforcement with fixture validation.
- **Troubleshooting guide:** Added setup and tooling troubleshooting documentation with cross-links from onboarding docs.

### Changed

- **verify-ci.sh hardening:** Improved ESLint v9 fallback behavior, repo-local temporary ignore handling, untracked-file scanning stability, and lint dependency checks with fewer side effects.
- **Installer safety and parity:** The installer now requires confirmation for dirty target repositories, initializes extension selection safely, enforces agent environment parity, and migrates legacy lizard configuration to current complexity extensions.
- **File-size enforcement:** Large generated or framework files now require structural refactoring toward the configured size target.
- **Agent instruction parity:** Codex, Claude, Cursor, and Copilot instructions remain aligned across root and install payloads.

### Fixed

- Prevented extension warning output from corrupting verify-ci.sh file collection.
- Fixed installer setup crashes caused by unset extension-selection state.

## v1.3.0 - 2026-05-08

### Added

- **Codex first-class support:** Added Codex configuration, agent instructions, and a review skill so Codex can follow CLARE autonomy and verification rules alongside Claude, Cursor, and Copilot.
- **CLARE install payload refresh:** The installer now ships CLARE-namespaced templates, examples, architecture tests, linting configs, GitHub Actions, and AI-tool instructions under the `clare/` layout.
- **CLARE branding assets:** Added the CLARE project image and renamed diagram/key references to match the CLARE namespace.

### Changed

- **Framework namespace renamed to CLARE:** Documentation, commands, rules, scripts, installer artifacts, release notes, and installed file paths now consistently use CLARE instead of CLEAR.
- **AI tool documentation updated:** Claude, Cursor, Copilot, and Codex guidance now points at `clare/verify-ci.sh`, `clare/autonomy.yml`, and the current CLARE workflow.
- **Release and installer naming aligned:** Release scripts now build and publish `clare-installer-vX.Y.Z` artifacts with CLARE signing-key documentation.

## v1.2.0 - 2026-05-05

### Added

- **`--update` flag for installer:** Updating an existing CLARE installation now requires `--update` explicitly. Running without it on an already-installed project errors and tells you exactly what to run. Per-file prompting on update: each changed file shows a `[U]pdate / (d)iff / (s)kip / (a)bort` prompt.
- **Codex support:** CLARE installer now supports OpenAI Codex as an AI tool target alongside Claude, Cursor, and Copilot.
- **Untracked file scanning in verify-ci.sh:** Architecture and autonomy checks now include untracked files by default. Use `--exclude-untracked` to limit scans to tracked files only.
- **Pre-publish notes preview:** Release script now shows a preview of release notes before publishing and offers an edit step.

### Changed

- **verify-ci.sh hardening:** More robust YAML parsing for autonomy paths, Python interpreter auto-detection, clearer warnings when Node tooling is missing, and improved `--help` output with flag validation.
- **Installer robustness:** Guards against missing TTY for interactive prompts, requires a git repository target, escapes extension names in sed selectors, and protects against `mktemp` failures.
- **Release script hardening:** Rejects detached HEAD before publishing, tighter semantic version validation, documented exit code meanings and break-glass flag implications.
- **Template and skill improvements:** Stronger autonomy guard parsing, clearer humans-only path selection guidance, expanded autonomy-bootstrap examples, and modernized MCP Python skill registration.
- **Documentation accuracy:** Fixed `--update` flag omission in README and getting-started guide, added 60-second CLARE overview, clarified template boundaries and breaking-change process.

## v1.1.0 - 2026-04-21

### Changed

- **Namespace consolidation:** All installed files now live under `clare/` instead of scattered across `scripts/` and `templates/`. This prevents collisions with existing project directories.
  - `scripts/verify-ci.sh` → `clare/verify-ci.sh`
  - `scripts/verify-local.sh` → `clare/verify-local.sh`
  - `templates/` → `clare/templates/`, `clare/examples/`, `clare/docs/`
- Templates, examples, and documentation are now installed into target projects so all config file references resolve to actual files.
- Unified installer now uses `install/` source layout that maps 1:1 to what gets installed.
- Setup wizard and installer behavior improvements: tighter verification rules, generic autonomy template, and better nested file handling.
- Examples moved out of onboarding bootstrap flow — available separately via `--install-examples`.

## v1.0.0 - 2026-04-21

Initial public release prepared from repository history (no prior release tags found).

### Added

- CLARE framework foundation with the five principles: Constrained, Limited, Assertive, Reality-Aligned, and Ephemeral.
- Bootstrap and setup workflow for existing projects with autonomy boundaries and source-of-truth onboarding.
- Unified install and update path via the CLARE installer.
- Local CI enforcement script (`scripts/verify-ci.sh`) plus project-owned extension points (`scripts/verify-local.sh`).
- Optional extension system and interactive extension setup support.
- Generic and example AI skills, including release prep and autonomy bootstrap guidance.
- Release automation scripts for installer/checksum/signature artifact generation.

### Changed

- Installer and release guidance now include explicit artifact/key download and signature verification instructions before execution.
- Release prep workflow now enforces docs/code accuracy checks and manual publish handoff due GPG passphrase entry.
- Setup wizard skill messaging updated for tool-agnostic assistant usage (Cursor, Copilot Chat, Claude, Codex, etc.).
- Project structure split between generic templates and domain-specific examples for safer adoption.

### Fixed

- Setup wizard interaction flow and prompt handling reliability improvements.
- Script linting/formatting/syntax guardrails integrated and validated via local verification.
- Multiple documentation accuracy updates for current script flags and supported workflows.
