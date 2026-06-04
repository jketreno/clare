# CLARE install-test Docker image

This folder contains a small Docker environment to run an end-to-end install smoke test for a project.

Purpose
- Build a reproducible Ubuntu 26.04 image with Go, Node (LTS), and Python (with venv/pipx).
- Clone a repository specified by `REPO_URL` and install CLARE into it from the mounted workspace.
- If the resulting repository contains `clare/verify-ci.sh`, run it with `--fast` to validate the installed CLARE scripts.

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
- The entrypoint clones `REPO_URL`, then installs CLARE into the clone using the mounted workspace: it runs `scripts/clare-installer.sh` directly from the mount, or — if the mount has no installer — falls back to a release-installer URL parsed from the mounted README, or finally to a fresh `git clone` of the CLARE repo. It does not run project-specific install commands (`npm ci`, `make install`, venv installs, `go build`) or parse arbitrary README prose.
- After install, if `clare/verify-ci.sh` exists it is run with `--fast`. The goal is to verify that CLARE installs and its scripts execute in a clean Ubuntu 26.04 environment.
