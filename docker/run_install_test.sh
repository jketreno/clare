#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
	echo "Usage: $0 <repo-url> [branch] [<extra docker args>...]" >&2
	echo "" >&2
	echo "Examples:" >&2
	echo "  $0 https://github.com/owner/repo.git" >&2
	echo "  $0 https://github.com/owner/repo.git main --no-cache" >&2
	exit 1
}

if [ $# -lt 1 ]; then
	usage
fi

REPO_URL="$1"
BRANCH="${2:-main}"

# Collect extra docker args passed after the branch (3rd+ positional args)
EXTRA_DOCKER_ARGS=()
if [ "$#" -gt 2 ]; then
	EXTRA_DOCKER_ARGS=("${@:3}")
fi

echo "Building docker image 'clare-install-test'..."
docker build -t clare-install-test docker

# Base docker run args
DOCKER_ARGS=(run --rm -e "REPO_URL=${REPO_URL}" -e "BRANCH=${BRANCH}")

# Disallow SSH-style repository URLs in the wrapper. This test harness
# requires public repositories (HTTPS) so we don't attempt to mount or
# forward SSH credentials from the host.
case "$REPO_URL" in
git@* | ssh://*)
	echo "ERROR: SSH-style REPO_URL is not supported by this test harness."
	echo "Please use a public HTTPS repository URL (e.g. https://github.com/owner/repo.git)" >&2
	exit 2
	;;
*) ;;
esac

# Map container user to host UID:GID so mounted keys keep correct perms
DOCKER_ARGS+=(--user "$(id -u):$(id -g)")

# Mount the local CLARE workspace (caller should run this script from the CLARE repo root).
# This provides the CLARE README and installer scripts to the container at runtime.
DOCKER_ARGS+=(-v "$(pwd)":/work/host_clare:ro)

# Append any extra docker args the caller provided
if [ "${#EXTRA_DOCKER_ARGS[@]}" -gt 0 ]; then
	DOCKER_ARGS+=("${EXTRA_DOCKER_ARGS[@]}")
fi

# Add image name
DOCKER_ARGS+=(clare-install-test)

echo "Running: docker ${DOCKER_ARGS[*]}"
docker "${DOCKER_ARGS[@]}"
