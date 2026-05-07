---
mode: agent
tools: ["run_in_terminal", "read_file", "apply_patch"]
model: GPT-5.3-Codex
---

# Release + README Sync

Use this prompt when asked to cut/publish a release.

## Steps

1. Run the release-prep workflow from `.github/skills/release.md`.
2. Audit `README.md` and all files in `docs/` against current script behavior by inspecting:
	- `./scripts/release.sh --help`
	- `./scripts/clare-installer.sh --help`
3. If docs mismatch implementation, abort and report a concise summary of incorrect files/commands.
4. Update `CHANGELOG.md` with user-relevant changes since last release tag (`v*`) or from repo start if no tags exist.
5. Update release collateral (`CHANGELOG.md`, `README.md`, and corrected docs) and run `./clare/verify-ci.sh`.
6. Stage, commit, and push collateral updates.
7. Hand off to user to publish manually:

```bash
./scripts/release.sh --version X.Y.Z --yes
```

Do not run release publish automatically; GPG passphrase entry is manual.
