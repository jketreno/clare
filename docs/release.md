# CLARE Release Runbook

This runbook describes the standard release flow for CLARE.

## Prerequisites

- Clean git tree on `main`
- GitHub CLI authenticated: `gh auth login`
- GPG configured for signing release checksums
- All required tools installed: `git`, `gh`, `gpg`, `tar`, `sha256sum`

## Release Command

```bash
./scripts/release.sh --yes
```

Optional flags:

```bash
./scripts/release.sh --version 1.2.3 --notes-file docs/release-notes/v1.2.3.md --yes
./scripts/release.sh --notes-template docs/release-notes-template.md --yes
./scripts/release.sh --dry-run
./scripts/release.sh --signing-key <gpg-key-id> --yes
```

If `--notes-file` is omitted, `release.sh` generates release notes from `docs/release-notes-template.md`.

Break-glass only:

```bash
./scripts/release.sh --skip-verify --yes
./scripts/release.sh --no-sign --yes
```

## What the release command does

1. Verifies preflight conditions (branch, clean tree, tools, auth)
2. Runs `./clare/verify-ci.sh` unless `--skip-verify` is explicitly used
3. Builds installer + checksum + detached signature artifacts
4. Creates and pushes `vX.Y.Z` tag
5. Creates GitHub release and uploads artifacts

## Release Artifacts

Each release publishes:

- `clare-installer-vX.Y.Z.sh`
- `clare-installer-vX.Y.Z.sha256`
- `clare-installer-vX.Y.Z.sha256.asc`

Repository trust material:

- `docs/keys/clare-release-signing-public.asc`
- `docs/keys/clare-release-signing-fingerprint.txt`

Published signing fingerprint:

- `35CD F523 D2E6 E479 53FC A25F A404 671B FB78 0D6E`

Release notes should repeat the same fingerprint to support out-of-band trust verification.

## Installer Usage

Download artifacts and verification key first:

```bash
curl -fsSLO https://github.com/jketreno/clare/releases/download/vX.Y.Z/clare-installer-vX.Y.Z.sh
curl -fsSLO https://github.com/jketreno/clare/releases/download/vX.Y.Z/clare-installer-vX.Y.Z.sha256
curl -fsSLO https://github.com/jketreno/clare/releases/download/vX.Y.Z/clare-installer-vX.Y.Z.sha256.asc
curl -fsSL -o clare-release-signing-public.asc \
	https://raw.githubusercontent.com/jketreno/clare/vX.Y.Z/docs/keys/clare-release-signing-public.asc
gpg --import clare-release-signing-public.asc
gpg --verify clare-installer-vX.Y.Z.sha256.asc clare-installer-vX.Y.Z.sha256
sha256sum -c clare-installer-vX.Y.Z.sha256
```

Do not run the installer unless verification succeeds.

Install or update from one entrypoint:

```bash
bash clare-installer-vX.Y.Z.sh --target /path/to/repo
```

Extract payload for inspection:

```bash
bash clare-installer-vX.Y.Z.sh --extract /tmp/clare-extract
```

Default installer execution uses ephemeral temp directories and removes extraction artifacts automatically.

## Recovery

If release creation fails after tag push, remove tag manually if rollback is intended:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
```
