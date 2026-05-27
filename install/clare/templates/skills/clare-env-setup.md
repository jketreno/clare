# CLARE Skill: clare-env-setup

description: Detect project file types, recommend tools and VS Code extensions, and optionally generate Dockerfile.clare for reproducible verification runs.

---

This skill provides an `env-scan` helper that inspects a repository, reports which languages and common config files are present, extracts tooling requirements from `clare/verify-ci.sh` and `clare/verify-local.sh`, and recommends VS Code extensions and install instructions.

Purpose
- Help contributors quickly configure their environment for CLARE verification.
- Provide a small `Dockerfile.clare` to run verification in an isolated container.

Usage
- Run the scanner (human-readable report):

  bash install/clare/scripts/clare-env-scan.sh --report

- Machine-readable JSON output:

  bash install/clare/scripts/clare-env-scan.sh --json > /tmp/clare-scan.json

- Attempt to update `.vscode/extensions.json` in the repository (use with care):

  bash install/clare/scripts/clare-env-scan.sh --apply-extensions --vscode-dir .vscode

Notes
- The scanner is intentionally conservative and will only auto-apply VS Code recommendations when explicitly requested.
- The included `install/Dockerfile.clare` is a suggested, minimal image to run `./clare/verify-ci.sh --fast` without polluting the host. Edit the Dockerfile to add or remove language runtimes as needed for your environment.

Outputs
- Plain text report (default `--report`).
- JSON (`--json`) with `fileCounts`, `configsFound`, `verifyTools`, and `recommendedExtensions` sections.

See `install/clare/README.md` for additional details and examples.
