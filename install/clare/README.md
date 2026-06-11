CLARE env-scan skill

This directory contains the `clare-env-scan` skill: a small helper that
inspects a repository for common files, extracts tooling requirements from
`clare/verify-ci.sh` and `clare/verify-local.sh`, and recommends VS Code
extensions.

Quick start

Run the human-readable report:

```bash
bash install/clare/scripts/clare-env-scan.sh --report
```

Print machine-readable JSON:

```bash
bash install/clare/scripts/clare-env-scan.sh --json > /tmp/clare-scan.json
```

Apply VS Code recommendations to a local `.vscode/extensions.json`:

```bash
bash install/clare/scripts/clare-env-scan.sh --apply-extensions --vscode-dir .vscode
```

Docker (optional)

Build the helper image (named `clare-verify`):

```bash
docker build -f install/Dockerfile.clare -t clare-verify .
```

Run the image mounted at the project root:

```bash
docker run --rm -v "$PWD":/work -w /work clare-verify
```

Go support in Dockerfile

The provided `install/Dockerfile.clare` now installs the Go toolchain from the official tarball by default (build-arg `GO_VERSION=1.22.9`). This makes language-specific checks that require `go` (for example `golangci-lint`) and tools installed via `go install` (for example `shfmt`) available in the image.

Build with a custom Go version:

```bash
docker build --build-arg GO_VERSION=1.22.9 -f install/Dockerfile.clare -t clare-verify .
```

To skip installing Go, pass an empty `GO_VERSION` build-arg:

```bash
docker build --build-arg GO_VERSION= -f install/Dockerfile.clare -t clare-verify .
```

The Dockerfile sets `GOBIN=/usr/local/bin` and adds `/usr/local/go/bin` to `PATH`, so `go install`-installed binaries are available system-wide.

Non-interactive skill install

The installer supports non-interactive skill installation using `--install-skill`. Pass a quoted list of numeric indices (as shown during the setup prompt) or the string `all`:

```bash
./scripts/clare-installer.sh --target /path/to/project --install-skill "1"
./scripts/clare-installer.sh --target /path/to/project --install-skill "all"
```

The `clare2-corpus-capture` skill additionally installs normalized capture
scripts and project hooks for Codex, Claude Code, and GitHub Copilot. Set
`CLARE2_CORPUS_ROOT` or `CLARE2_ROOT` before starting those agents.

Notes
- The Dockerfile installs Go by default; pass `--build-arg GO_VERSION=` to skip it,
  and add other runtimes (e.g. Rust) if you need them for `verify-ci.sh` checks.
- The script tries to use Python 3 to produce JSON; if Python is unavailable the
  script will still print a human-readable report but JSON mode will fail.
