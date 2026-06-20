#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALLER="$ROOT/scripts/clare-installer.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

new_empty_project() {
  local project="$1"
  mkdir -p "$project"
  git -C "$project" init -q
}

test_noninteractive_without_yes_skips_clare_next() {
  local project="$TEMP/no-next"
  new_empty_project "$project"

  "$INSTALLER" --target "$project" >/dev/null

  [[ ! -f "$project/CLARE-NEXT.md" ]]
}

test_yes_creates_clare_next() {
  local project="$TEMP/with-next"
  new_empty_project "$project"
  mkdir -p "$project/frontend"
  printf '%s\n' '{"scripts":{"build":"vite build"}}' >"$project/frontend/package.json"

  "$INSTALLER" --target "$project" --yes >/dev/null

  [[ -f "$project/CLARE-NEXT.md" ]]
  grep -q '<!-- CLARE-NEXT:BEGIN -->' "$project/CLARE-NEXT.md"
  grep -q 'Deployment parity' "$project/CLARE-NEXT.md"
  grep -q 'frontend/package.json' "$project/CLARE-NEXT.md"
}

test_existing_notes_are_preserved() {
  local project="$TEMP/preserve-notes"
  new_empty_project "$project"

  "$INSTALLER" --target "$project" --yes >/dev/null
  printf '\nTeam note: keep this.\n' >>"$project/CLARE-NEXT.md"
  "$INSTALLER" --setup-only --target "$project" --yes >/dev/null

  grep -q 'Team note: keep this.' "$project/CLARE-NEXT.md"
}

test_noninteractive_without_yes_skips_clare_next
test_yes_creates_clare_next
test_existing_notes_are_preserved
echo "CLARE-NEXT installer tests passed"
