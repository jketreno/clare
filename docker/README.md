# CLARE install-test Docker image

This folder contains a small Docker environment to run an end-to-end install smoke test for a project.

Purpose
- Build a reproducible Ubuntu 26.04 image with Go, Node (LTS), and Python (with venv/pipx).
- Clone a repository specified by `REPO_URL` and attempt common installation commands (best-effort).
- If the repository contains `clare/verify-ci.sh`, run it with `--fast` to validate CLARE scripts.

Usage

1. Build and run the test against a repository:

```bash
./docker/run_install_test.sh https://github.com/your/repo.git [branch]
```

2. The container expects the environment variable `REPO_URL`. Optionally set `BRANCH`.

CLARE-based install steps

- This test harness runs the install steps from the local CLARE workspace (the harness repo), not the cloned project's README. The runner mounts your CLARE workspace into the container at `/work/host_clare` (read-only), and the entrypoint runs `scripts/clare-installer.sh` directly from that mount against the cloned project. If the mount has no installer script, the entrypoint falls back to a release-installer URL parsed from the mounted README, or finally to a fresh `git clone` of the CLARE repo.

- For typical usage, run the wrapper which automatically mounts the CLARE workspace for you:

```bash
./docker/run_install_test.sh https://github.com/your/repo.git [branch]
```

- This harness requires the target repository to be public (HTTPS). SSH-style URLs are not supported by the wrapper.

Notes
- The entrypoint performs a best-effort sequence of install steps (install.sh, scripts/install.sh, `npm ci`, `make install`, Python venv installs, `go build`). It does not try to parse arbitrary README prose.
- The goal is to verify the runtime/toolchain presence and that the project's install scripts can execute in a clean Ubuntu 26.04 environment.
