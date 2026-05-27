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

Notes
- The Dockerfile is intentionally minimal; add additional runtimes (Go, Rust)
  if you need to run language-specific checks in `verify-ci.sh`.
- The script tries to use Python 3 to produce JSON; if Python is unavailable the
  script will still print a human-readable report but JSON mode will fail.
