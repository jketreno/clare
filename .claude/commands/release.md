# /project:release — Publish release and sync README

Use this command when asked to cut or publish a release.

## Instructions

1. Read and follow `.github/skills/release.md` exactly.
2. Run `./scripts/release.sh --yes` (or with explicit `--version` when provided).
3. Verify release publication and uploaded assets.
4. Update README "CLARE in 60 Seconds" to the new release:
   - replace only content between `<!-- RELEASE_VERSION_START -->` and `<!-- RELEASE_VERSION_END -->`
   - set version label + link to latest release tag
   - include minimal installer commands with exact `clare-installer-vX.Y.Z.sh` filename
5. Run `./clare/verify-ci.sh` before reporting complete.

## Output format

```
## Release Result

Status: ✅ PASSED / ❌ FAILED
Version: vX.Y.Z
Release URL: https://github.com/jketreno/clare/releases/tag/vX.Y.Z

Assets:
- clare-installer-vX.Y.Z.sh
- clare-installer-vX.Y.Z.sha256
- clare-installer-vX.Y.Z.sha256.asc

README synced: yes/no
```
