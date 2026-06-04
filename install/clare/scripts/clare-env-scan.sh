#!/usr/bin/env bash
set -euo pipefail

# Simple environment scanner for CLARE
# Outputs a human-readable report or JSON describing file types, config
# files found, and tools referenced by clare/verify-*.sh.

usage() {
  cat <<'USAGE'
Usage: clare-env-scan.sh [--report|--json] [--apply-extensions] [--vscode-dir <path>]

Options:
  --report            Print human-readable report (default)
  --json              Emit JSON to stdout
  --apply-extensions  Attempt to write recommended extensions to <vscode-dir>/extensions.json
  --vscode-dir <dir>  Directory containing VS Code config (default: .vscode)
  --help              Show this help
USAGE
}

MODE=report
APPLY_EXT=false
VSCODE_DIR=".vscode"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)
      MODE=report
      shift
      ;;
    --json)
      MODE=json
      shift
      ;;
    --apply-extensions)
      APPLY_EXT=true
      shift
      ;;
    --vscode-dir)
      VSCODE_DIR="${2:-.vscode}"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_ROOT"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# 1) File counts by extension
declare -A counts
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  if [[ "$base" != *.* ]]; then
    ext="no_extension"
  else
    ext=".${base##*.}"
  fi
  counts["$ext"]=$((counts["$ext"] + 1))
done < <(find . -type f -not -path './.git/*' -print0)

# Write counts to temp file for JSON stage
echo "{" >"$TMPDIR/fileCounts.json"
first=true
for k in "${!counts[@]}"; do
  if [[ "$first" == true ]]; then first=false; else echo "," >>"$TMPDIR/fileCounts.json"; fi
  printf '  "%s": %d' "${k}" "${counts[$k]}" >>"$TMPDIR/fileCounts.json"
done
printf '\n}\n' >>"$TMPDIR/fileCounts.json"

# 2) Detect key config files
configs=(
  package.json
  package-lock.json
  yarn.lock
  tsconfig.json
  pyproject.toml
  requirements.txt
  setup.cfg
  Dockerfile
  docker-compose.yml
  .github/workflows/ci.yml
  clare/verify-ci.sh
  clare/verify-local.sh
  clare/autonomy.yml
  clare/extensions.yml
)
: >"$TMPDIR/configs.txt"
for c in "${configs[@]}"; do
  if [[ -f "$PROJECT_ROOT/$c" || -d "$PROJECT_ROOT/$c" ]]; then
    echo "$c" >>"$TMPDIR/configs.txt"
  fi
done

# 3) Parse verify scripts for known tool tokens
verify_files=("clare/verify-ci.sh" "clare/verify-local.sh")
: >"$TMPDIR/tools.txt"
for vf in "${verify_files[@]}"; do
  if [[ -f "$PROJECT_ROOT/$vf" ]]; then
    # Extract tokens of likely tools
    grep -Eio 'node|npm|npx|eslint|prettier|typescript|tsc|yq|python3|python|pipx|pip|pyyaml|shellcheck|shfmt|rg|ripgrep|ruff|flake8|mypy|pytest|go|golangci-lint|golint|cargo|rust|jq|docker|tput|git|shfmt|shellmetrics|complexipy' "$PROJECT_ROOT/$vf" 2>/dev/null || true \
      | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' '\n' | sort -u | while read -r token; do
      echo "$token|$vf"
    done
  fi
done | sort -u >"$TMPDIR/tools.txt"

# Helper: map tool -> install hint + includeInDocker
map_tool() {
  local t="$1"
  # Use a small Python mapping here to keep shell cyclomatic complexity low
  python3 - "$t" <<'PY'
import sys
t = sys.argv[1]
m = {
  'node': "Install Node.js (NodeSource or official distro image). Use npm ci to install project devDependencies.",
  'npm': "Install Node.js (NodeSource or official distro image). Use npm ci to install project devDependencies.",
  'npx': "Install Node.js (NodeSource or official distro image). Use npm ci to install project devDependencies.",
  'eslint': "npm install --save-dev eslint (or use project devDependencies)",
  'prettier': "npm install --save-dev prettier",
  'typescript': "npm install --save-dev typescript",
  'tsc': "npm install --save-dev typescript",
  'yq': "Install mikefarah yq binary (https://github.com/mikefarah/yq) or use distro package",
  'python3': "Install Python 3 and pip (apt: python3 python3-pip). Use pipx for global CLIs.",
  'python': "Install Python 3 and pip (apt: python3 python3-pip). Use pipx for global CLIs.",
  'pip': "Install Python 3 and pip (apt: python3 python3-pip). Use pipx for global CLIs.",
  'pipx': "Install Python 3 and pip (apt: python3 python3-pip). Use pipx for global CLIs.",
  'pyyaml': "pip install pyyaml",
  'shellcheck': "apt-get install shellcheck (or use distro package)",
  'shfmt': "Install shfmt (go install mvdan.cc/sh/v3/cmd/shfmt@latest or download binary)",
  'rg': "apt-get install ripgrep (optional)",
  'ripgrep': "apt-get install ripgrep (optional)",
  'ruff': "pip install ruff",
  'flake8': "pip install flake8",
  'mypy': "pip install mypy",
  'pytest': "pip install pytest",
  'go': "Install Go toolchain (apt or official image) and golangci-lint via 'go install'",
  'golangci-lint': "Install Go toolchain (apt or official image) and golangci-lint via 'go install'",
  'golint': "Install Go toolchain (apt or official image) and golangci-lint via 'go install'",
  'cargo': "Install Rust via rustup (if you need Rust checks)",
  'rust': "Install Rust via rustup (if you need Rust checks)",
  'jq': "apt-get install jq",
  'docker': "Install Docker CLI if you intend to run containers locally",
  'tput': "Provided by ncurses (apt-get install ncurses-bin)",
  'git': "Install git (apt-get install git)",
  'shellmetrics': "Project-specific Python packages; verify exact package name in clare/extensions.yml",
  'complexipy': "Project-specific Python packages; verify exact package name in clare/extensions.yml",
}
print(m.get(t, f"Check project files or verify scripts for how {t} is used"))
PY
}

# 4) Build verifyTools JSON structure
: >"$TMPDIR/verifyTools.jsonl"
if [[ -f "$TMPDIR/tools.txt" ]]; then
  while IFS='|' read -r tool where; do
    [[ -z "$tool" ]] && continue
    hint="$(map_tool "$tool")"
    include="false"
    case "$tool" in
      node | npm | npx | eslint | prettier | typescript | tsc | yq | python3 | python | pip | jq | shellcheck | shfmt | git | tput)
        include="true"
        ;;
    esac
    python3 - "$tool" "$where" "$hint" "$include" <<PY >>"$TMPDIR/verifyTools.jsonl" 2>/dev/null || true
  import json,sys
  obj={'tool': sys.argv[1], 'whereFound': sys.argv[2].split(','), 'installHint': sys.argv[3], 'includeInDocker': sys.argv[4]=='true'}
  print(json.dumps(obj))
PY
  done <"$TMPDIR/tools.txt"
fi

# 5) Recommended VS Code extensions (basic set)
cat >"$TMPDIR/recommended_extensions.json" <<JSON
[
  {"extension":"eamodio.gitlens","reason":"Git history and blame"},
  {"extension":"EditorConfig.EditorConfig","reason":"Enforce editor settings"},
  {"extension":"dbaeumer.vscode-eslint","reason":"ESLint integration"},
  {"extension":"esbenp.prettier-vscode","reason":"Formatting with Prettier"},
  {"extension":"timonwong.shellcheck","reason":"ShellCheck in-editor linting"},
  {"extension":"redhat.vscode-yaml","reason":"YAML schema and validation"},
  {"extension":"ms-python.python","reason":"Python language support (optional)"},
  {"extension":"ms-azuretools.vscode-docker","reason":"Dockerfile authoring"},
  {"extension":"yzhang.markdown-all-in-one","reason":"Markdown productivity"}
]
JSON

# 6) Emit results
if [[ "$MODE" == "json" ]]; then
  python3 - <<PY
import json,sys,os
root='.'
with open('$TMPDIR/fileCounts.json') as f:
  fileCounts=json.load(f)
configs=[]
if os.path.exists('$TMPDIR/configs.txt'):
  with open('$TMPDIR/configs.txt') as f:
    configs=[l.strip() for l in f if l.strip()]
verifyTools=[]
if os.path.exists('$TMPDIR/verifyTools.jsonl'):
  for line in open('$TMPDIR/verifyTools.jsonl'):
    try:
      verifyTools.append(json.loads(line))
    except Exception:
      pass
recommended=json.load(open('$TMPDIR/recommended_extensions.json'))
out={'fileCounts': fileCounts, 'configsFound': configs, 'verifyTools': verifyTools, 'recommendedExtensions': recommended}
print(json.dumps(out, indent=2))
PY
  exit 0
fi

# Human readable report
echo "CLARE environment scan for: $PROJECT_ROOT"
echo ""
echo "File counts (by extension):"
python3 - <<PY
import json
print('\n'.join([f"  {k}: {v}" for k,v in json.load(open('$TMPDIR/fileCounts.json')).items()]))
PY

echo ""
if [[ -s "$TMPDIR/configs.txt" ]]; then
  echo "Detected config files:"
  sed -e 's/^/  - /' "$TMPDIR/configs.txt" || true
else
  echo "No common config files detected"
fi

echo ""
if [[ -s "$TMPDIR/verifyTools.jsonl" ]]; then
  echo "Tools referenced by verify scripts:"
  python3 - <<PY
import json
for line in open('$TMPDIR/verifyTools.jsonl'):
  try:
    obj=json.loads(line)
    print(f"  - {obj['tool']}: {obj['installHint']} (includeInDocker={obj['includeInDocker']})")
  except Exception:
    pass
PY
else
  echo "No tools referenced in clare/verify-*.sh found."
fi

echo ""
echo "Recommended VS Code extensions:"
python3 - <<PY
import json
for e in json.load(open('$TMPDIR/recommended_extensions.json')):
  print(f"  - {e['extension']}: {e['reason']}")
PY

if [[ "$APPLY_EXT" == true ]]; then
  mkdir -p "$VSCODE_DIR"
  extfile="$VSCODE_DIR/extensions.json"
  if [[ -f "$extfile" ]]; then
    echo "Backing up existing $extfile -> $extfile.bak"
    cp "$extfile" "$extfile.bak"
  fi
  python3 - <<PY
import json
rec=json.load(open('$TMPDIR/recommended_extensions.json'))
with open('$extfile','w') as f:
  json.dump({'recommendations':[r['extension'] for r in rec]},f,indent=2)
print('Wrote', '$extfile')
PY
fi

exit 0
