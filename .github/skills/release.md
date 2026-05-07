---
name: release
description: "Prepare release collateral by auditing docs, updating CHANGELOG, and committing/pushing changes; hand off publish to human due signing passphrase."
mode: agent
---

# CLARE Repo Skill: Prepare a Release

Use this skill when a user asks to prepare or cut a release for this repository.
This skill does not publish the release directly.

## Non-negotiables

1. Git tree must be clean before starting.
2. Release must run from `main`.
3. `./clare/verify-ci.sh` must pass before handoff.
4. Before release prep, audit docs for command/flag accuracy by inspecting scripts.
5. If docs and implementation disagree, abort prep and report a mismatch summary.
6. Update release collateral, then stage, commit, and push before handoff.
7. Do not run `./scripts/release.sh` automatically because signing requires manual passphrase entry.
8. Update README release version block by replacing only the content between:
   - `<!-- RELEASE_VERSION_START -->`
   - `<!-- RELEASE_VERSION_END -->`
9. The updated block must include:
   - the new version label `vX.Y.Z`
   - a link to `https://github.com/jketreno/clare/releases/tag/vX.Y.Z`
   - install commands with exact installer filename for that version

## Phase 1: Preflight + Accuracy Audit

Run:

```bash
git status --porcelain
git branch --show-current
./clare/verify-ci.sh
```

Inspect script capabilities and compare with README/docs references:

```bash
./scripts/release.sh --help
./scripts/clare-installer.sh --help
```

Verify README and all files under `docs/` only reference supported commands and flags.

Abort criteria:
- Any command in README/docs uses unsupported script flags
- Any release instructions refer to removed scripts
- Any required prerequisites are outdated or missing

If aborting, provide a concise mismatch summary with file paths and exact incorrect command snippets.

## Phase 2: Changelog Update

Determine the release baseline:

```bash
LAST_TAG="$(git tag -l 'v*' --sort=-version:refname --merged HEAD | head -1)"
```

If `LAST_TAG` exists, summarize user-relevant changes from `LAST_TAG..HEAD`.
If no tag exists, summarize user-relevant changes from repo start.

Update `CHANGELOG.md` with:
- new release heading `vX.Y.Z`
- concise user-facing summary of features/fixes/behavior changes
- no internal-only noise unless it affects users

## Phase 3: Release Collateral Commit

Update release collateral files as needed, including:
- `CHANGELOG.md`
- `README.md` release marker block
- any docs touched during audit corrections

Then stage and commit:

```bash
git add CHANGELOG.md README.md docs/
git commit -m "chore(release): prepare vX.Y.Z collateral"
git push origin main
```

## Phase 4: Human Publish Handoff

After push, instruct the user to run release publish manually:

```bash
./scripts/release.sh --version X.Y.Z --yes
```

Explain that this manual step is required because GPG passphrase entry cannot be automated reliably.

## Required output checks (prep mode)

1. Docs/script audit passed (or aborted with mismatch summary)
2. `CHANGELOG.md` updated from last tag (or repo start)
3. Release collateral committed and pushed
4. Clear handoff command provided for manual publish

## README tagged block template (collateral prep)

Replace only the content between the tag markers with:

~~~markdown
<!-- RELEASE_VERSION_START -->
**Latest release: [vX.Y.Z](https://github.com/jketreno/clare/releases/tag/vX.Y.Z)**

```bash
curl -fsSLO https://github.com/jketreno/clare/releases/download/vX.Y.Z/clare-installer-vX.Y.Z.sh
chmod +x ./clare-installer-vX.Y.Z.sh
./clare-installer-vX.Y.Z.sh --target /path/to/your-project
```
<!-- RELEASE_VERSION_END -->
~~~
