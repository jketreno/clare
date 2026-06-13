#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALLER="$ROOT/scripts/clare-installer.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

new_project() {
  local project="$1"
  mkdir -p "$project/clare" "$project/.vscode" "$project/clare/templates/hooks" "$project/clare/templates/scripts"
  cp "$ROOT/install/clare/autonomy.yml" "$project/clare/autonomy.yml"
  cp "$ROOT/install/.vscode/settings.json" "$project/.vscode/settings.json"
  cp "$ROOT/install/.vscode/extensions.json" "$project/.vscode/extensions.json"
  cp "$ROOT/install/.vscode/tasks.json" "$project/.vscode/tasks.json"
  cp -R "$ROOT/install/clare/templates/hooks/." "$project/clare/templates/hooks/"
  cp "$ROOT/install/clare/templates/scripts/clare2-capture-event.sh" \
    "$ROOT/install/clare/templates/scripts/clare2-install-hooks.sh" \
    "$project/clare/templates/scripts/"
  git -C "$project" init -q
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qm initial
}

test_merge_preserves_project_additions() {
  local project="$TEMP/merge-project"
  new_project "$project"

  jq '. + {"workbench.iconTheme": "vs-seti"}' \
    "$project/.vscode/settings.json" >"$project/.vscode/settings.json.tmp"
  mv "$project/.vscode/settings.json.tmp" "$project/.vscode/settings.json"

  jq '.recommendations += ["my-team.custom-ext"]' \
    "$project/.vscode/extensions.json" >"$project/.vscode/extensions.json.tmp"
  mv "$project/.vscode/extensions.json.tmp" "$project/.vscode/extensions.json"

  jq '.tasks += [{"label": "My Custom Task", "type": "shell", "command": "echo hi"}]' \
    "$project/.vscode/tasks.json" >"$project/.vscode/tasks.json.tmp"
  mv "$project/.vscode/tasks.json.tmp" "$project/.vscode/tasks.json"

  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qam customize

  # Drop a CLARE-recommended extension and task so the merge has something
  # to add back.
  jq 'del(.recommendations[] | select(. == "eamodio.gitlens"))' \
    "$project/.vscode/extensions.json" >"$project/.vscode/extensions.json.tmp"
  mv "$project/.vscode/extensions.json.tmp" "$project/.vscode/extensions.json"
  jq 'del(.tasks[] | select(.label == "CLARE: Verify CI (fail-fast)"))' \
    "$project/.vscode/tasks.json" >"$project/.vscode/tasks.json.tmp"
  mv "$project/.vscode/tasks.json.tmp" "$project/.vscode/tasks.json"
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qam trim

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null

  jq -e '."workbench.iconTheme" == "vs-seti"' \
    "$project/.vscode/settings.json" >/dev/null
  jq -e '."yaml.schemas" != null' \
    "$project/.vscode/settings.json" >/dev/null

  jq -e '.recommendations | index("my-team.custom-ext") != null' \
    "$project/.vscode/extensions.json" >/dev/null
  jq -e '.recommendations | index("eamodio.gitlens") != null' \
    "$project/.vscode/extensions.json" >/dev/null

  jq -e '.tasks | map(.label) | index("My Custom Task") != null' \
    "$project/.vscode/tasks.json" >/dev/null
  jq -e '.tasks | map(.label) | index("CLARE: Verify CI (fail-fast)") != null' \
    "$project/.vscode/tasks.json" >/dev/null
}

test_merge_is_idempotent() {
  local project="$TEMP/idempotent-project"
  new_project "$project"

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  local before
  before="$(git -C "$project" status --porcelain)"

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null
  local after
  after="$(git -C "$project" status --porcelain)"

  [[ "$before" == "$after" ]]
}

test_dirty_file_is_skipped() {
  local project="$TEMP/dirty-project"
  new_project "$project"

  jq '.recommendations += ["my-team.custom-ext"]' \
    "$project/.vscode/extensions.json" >"$project/.vscode/extensions.json.tmp"
  mv "$project/.vscode/extensions.json.tmp" "$project/.vscode/extensions.json"

  local before
  before="$(cat "$project/.vscode/extensions.json")"

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null

  local after
  after="$(cat "$project/.vscode/extensions.json")"

  [[ "$before" == "$after" ]]
}

test_untracked_file_is_skipped() {
  local project="$TEMP/untracked-project"
  new_project "$project"

  rm "$project/.vscode/tasks.json"
  printf '{"version": "2.0.0", "tasks": []}\n' >"$project/.vscode/tasks.json"

  local before
  before="$(cat "$project/.vscode/tasks.json")"

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null

  local after
  after="$(cat "$project/.vscode/tasks.json")"

  [[ "$before" == "$after" ]]
}

test_dirty_and_untracked_hook_configs_are_preserved() {
  local project="$TEMP/hook-config-project"
  new_project "$project"
  mkdir -p "$project/.codex" "$project/.claude"
  printf '%s\n' '{"hooks":{}}' >"$project/.codex/hooks.json"
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qm hooks

  printf '%s\n' '{"hooks":{},"local":"dirty"}' >"$project/.codex/hooks.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(custom)"]}}' \
    >"$project/.claude/settings.json"
  local codex_before claude_before
  codex_before="$(cat "$project/.codex/hooks.json")"
  claude_before="$(cat "$project/.claude/settings.json")"

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null

  [[ "$codex_before" == "$(cat "$project/.codex/hooks.json")" ]]
  [[ "$claude_before" == "$(cat "$project/.claude/settings.json")" ]]
  jq -e '.hooks.sessionStart | length == 1' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
}

test_clare2_assets_are_authoritative_and_restricted() {
  local project="$TEMP/clare2-project"
  new_project "$project"
  mkdir -p "$project/clare2/scripts" "$project/clare2/templates/hooks"

  cat >"$project/clare2/scripts/clare2-install-hooks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
project=$1
mkdir -p "$project/.github/hooks"
printf '{"version":1,"source":"clare2"}\n' \
  >"$project/.github/hooks/clare2-corpus.json"
touch "$project/clare2-installer-ran"
EOF
  printf '{"source":"clare2"}\n' \
    >"$project/clare2/templates/hooks/copilot-hooks.json"
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qm clare2

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null

  [[ -f "$project/clare2-installer-ran" ]]
  [[ ! -x "$project/clare2/scripts/clare2-install-hooks.sh" ]]
  jq -e '.source == "clare2"' \
    "$project/.github/hooks/clare2-corpus.json" >/dev/null
  grep -A2 'path: "clare2"$' "$project/clare/autonomy.yml" \
    | grep -q 'level: supervised'
  grep -A2 'path: "clare2/templates/hooks"$' "$project/clare/autonomy.yml" \
    | grep -q 'level: humans-only'
  grep -A2 'path: "clare2/scripts/clare2-install-hooks.sh"$' \
    "$project/clare/autonomy.yml" | grep -q 'level: humans-only'

  local before
  before="$(cat "$project/clare/autonomy.yml")"
  git -C "$project" -c user.email=test@example.com -c user.name=test add -A
  git -C "$project" -c user.email=test@example.com -c user.name=test commit -qm updated

  "$INSTALLER" --update --target "$project" --yes --no-setup >/dev/null

  [[ "$before" == "$(cat "$project/clare/autonomy.yml")" ]]
}

test_merge_preserves_project_additions
test_merge_is_idempotent
test_dirty_file_is_skipped
test_untracked_file_is_skipped
test_dirty_and_untracked_hook_configs_are_preserved
test_clare2_assets_are_authoritative_and_restricted
echo "CLARE .vscode JSON merge tests passed"
