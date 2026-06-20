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
      # Guard the value: a trailing `--vscode-dir` with no argument would make
      # `shift 2` fail on a single-element list under `set -e`, exiting with no
      # message. Require an explicit value instead.
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--vscode-dir requires a value" >&2
        usage
        exit 2
      fi
      VSCODE_DIR="$2"
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
  counts["$ext"]=$((${counts["$ext"]:-0} + 1))
  # Prune vendored/build directories so file counts characterize the project
  # itself, not its dependencies (e.g. node_modules can dwarf real source files).
done < <(find . \
  \( -path './.git' -o -path './node_modules' -o -path './dist' \
  -o -path './build' -o -path './.venv' -o -path './venv' -o -path './vendor' \) -prune \
  -o -type f -print0)

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
    # Extract tokens of likely tools. The `|| true` is scoped so the rest of
    # the pipeline always runs on grep's output (matches go to the transform);
    # without the braces, `|| true` would short-circuit the whole pipe.
    #
    # Tokens are wrapped in \b…\b word boundaries so short names like `go` and
    # `git` don't match inside unrelated words (e.g. `golang`, `digit`). Longer
    # alternatives (golangci-lint, python3, ripgrep) are listed before their
    # shorter prefixes so leftmost-first alternation prefers the specific match.
    { grep -Eio '\b(golangci-lint|golint|ripgrep|typescript|shellcheck|shellmetrics|complexipy|prettier|pyyaml|python3|pytest|flake8|eslint|docker|cargo|shfmt|python|pipx|mypy|tput|rust|ruff|node|npm|npx|tsc|pip|yq|rg|go|jq|git)\b' "$PROJECT_ROOT/$vf" 2>/dev/null || true; } \
      | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' '\n' | sort -u | while read -r token; do
      [[ -z "$token" ]] && continue
      echo "$token|$vf"
    done
  fi
done | sort -u >"$TMPDIR/tools_raw.txt"

# Aggregate to one row per tool, joining every verify file it appeared in into a
# single comma-separated whereFound list. Without this, a tool referenced in both
# verify scripts would emit two separate rows, doubling the report.
awk -F'|' '
  { if ($1 in seen) { files[$1] = files[$1] "," $2 } else { seen[$1] = 1; files[$1] = $2; order[++n] = $1 } }
  END { for (i = 1; i <= n; i++) print order[i] "|" files[order[i]] }
' "$TMPDIR/tools_raw.txt" >"$TMPDIR/tools.txt"

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
    python3 - "$tool" "$where" "$hint" "$include" <<'PY' >>"$TMPDIR/verifyTools.jsonl"
import json, sys
obj = {'tool': sys.argv[1], 'whereFound': sys.argv[2].split(','), 'installHint': sys.argv[3], 'includeInDocker': sys.argv[4] == 'true'}
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

# 6) Deployment/readiness surface scan. This is heuristic by design: it helps
# humans and agents see likely gates that need project-specific CLARE wiring,
# while enforcement remains in verify-ci.sh / verify-local.sh.
PROJECT_ROOT="$PROJECT_ROOT" TMPDIR="$TMPDIR" python3 - <<'PYREADINESS'
import json
import os
import re
from pathlib import Path

root = Path(os.environ['PROJECT_ROOT']).resolve()
tmp = Path(os.environ['TMPDIR'])
skip_dirs = {'.git', 'node_modules', 'dist', 'build', '.venv', 'venv', 'vendor', '__pycache__'}
verify_text = ''
for rel in ('clare/verify-ci.sh', 'clare/verify-local.sh'):
    p = root / rel
    if p.exists():
        verify_text += '\n' + p.read_text(errors='ignore')

surfaces = []
seen = set()

def relpath(path):
    return str(path.relative_to(root))

def add(kind, name, path, command='', reason='', confidence='medium'):
    key = (kind, name, path, command)
    if key in seen:
        return
    seen.add(key)
    surfaces.append({
        'kind': kind,
        'name': name,
        'path': path,
        'command': command,
        'reason': reason,
        'confidence': confidence,
    })

def is_skipped(path):
    return any(part in skip_dirs for part in path.parts)

for package_json in sorted(root.rglob('package.json')):
    if is_skipped(package_json.relative_to(root)):
        continue
    try:
        data = json.loads(package_json.read_text())
    except Exception:
        data = {}
    pkg_dir = package_json.parent
    pkg_rel = relpath(pkg_dir)
    add('node-package', data.get('name') or pkg_rel or '.', relpath(package_json),
        f"cd {pkg_rel or '.'} && npm install", 'Node package manifest discovered', 'high')
    scripts = data.get('scripts') or {}
    for script_name in sorted(scripts):
        if re.search(r'(build|lint|type|test|check|ci|deploy|prod|format)', script_name, re.I):
            add('node-script', script_name, relpath(package_json),
                f"cd {pkg_rel or '.'} && npm run {script_name}",
                f"package.json script looks like a verification/deployment gate: {script_name}", 'high')

for makefile in sorted([p for p in root.rglob('Makefile') if not is_skipped(p.relative_to(root))]):
    lines = makefile.read_text(errors='ignore').splitlines()
    for line in lines:
        m = re.match(r'^([A-Za-z0-9_.-]+)\s*:(?![=])', line)
        if not m:
            continue
        target = m.group(1)
        if target.startswith('.'):
            continue
        if re.search(r'(build|front|prod|deploy|release|test|lint|check|ci|verify)', target, re.I):
            mf_dir = makefile.parent
            dir_rel = relpath(mf_dir)
            prefix = f"cd {dir_rel} && " if dir_rel != '.' else ''
            add('make-target', target, relpath(makefile), f"{prefix}make {target}",
                f"Make target name looks relevant to build/test/deploy: {target}", 'medium')

for marker in ('pyproject.toml', 'setup.py', 'requirements.txt', 'tox.ini', 'noxfile.py'):
    for p in sorted(root.rglob(marker)):
        if is_skipped(p.relative_to(root)):
            continue
        add('python-project', marker, relpath(p), '', 'Python project/config file discovered', 'medium')

for p in sorted(root.rglob('go.mod')):
    if not is_skipped(p.relative_to(root)):
        d = relpath(p.parent)
        add('go-module', 'go test/build', relpath(p), f"cd {d} && go test ./...", 'Go module discovered', 'high')

for p in sorted(root.rglob('Cargo.toml')):
    if not is_skipped(p.relative_to(root)):
        d = relpath(p.parent)
        add('rust-crate', 'cargo test/build', relpath(p), f"cd {d} && cargo test", 'Rust crate discovered', 'high')

compose_names = {'docker-compose.yml', 'docker-compose.yaml', 'compose.yml', 'compose.yaml'}
for p in sorted([p for p in root.rglob('*') if p.name in compose_names and not is_skipped(p.relative_to(root))]):
    add('docker-compose', p.name, relpath(p), f"docker compose -f {relpath(p)} config", 'Docker Compose file discovered', 'medium')
    text = p.read_text(errors='ignore')
    in_services = False
    for line in text.splitlines():
        if re.match(r'^services:\s*$', line):
            in_services = True
            continue
        if in_services and re.match(r'^[A-Za-z0-9_-]+:', line):
            break
        m = re.match(r'^  ([A-Za-z0-9_.-]+):\s*$', line)
        if in_services and m:
            service = m.group(1)
            add('docker-compose-service', service, relpath(p), f"docker compose -f {relpath(p)} up -d {service}",
                f"Docker Compose service discovered: {service}", 'medium')

for p in sorted(root.rglob('Dockerfile*')):
    if not is_skipped(p.relative_to(root)):
        add('dockerfile', p.name, relpath(p), f"docker build -f {relpath(p)} .", 'Dockerfile discovered', 'medium')

workflow_dir = root / '.github' / 'workflows'
if workflow_dir.is_dir():
    for p in sorted(workflow_dir.glob('*.yml')) + sorted(workflow_dir.glob('*.yaml')):
        add('github-actions', p.name, relpath(p), '', 'GitHub Actions workflow discovered', 'medium')

verified = []
gaps = []
for surface in surfaces:
    tokens = [surface.get('path', ''), surface.get('command', ''), surface.get('name', '')]
    covered = any(token and token in verify_text for token in tokens)
    entry = dict(surface)
    entry['coverage'] = 'verified' if covered else 'gap'
    entry['coverageReason'] = 'Referenced by clare/verify-ci.sh or clare/verify-local.sh' if covered else 'No obvious reference in CLARE verification scripts'
    if covered:
        verified.append(entry)
    else:
        gaps.append(entry)

if gaps:
    prompt = """Analyze this repository's detected build, lint, test, and deployment surfaces and update CLARE so ./clare/verify-ci.sh catches the gates required before deployment. Use the detected surfaces in CLARE-NEXT.md or clare/scripts/clare-env-scan.sh --json. Update project-owned CLARE files only, such as clare/verify-local.sh, clare/extensions.yml, or clare/autonomy.yml when appropriate. Do not edit CLARE-owned generated files or humans-only paths. Prefer checks that run the same commands used by deployment, including containerized commands when deployment uses containers. After changes, run ./clare/verify-ci.sh once and report PASS/FAIL."""
else:
    prompt = """Review this repository's CLARE setup and confirm that ./clare/verify-ci.sh covers the same build, lint, test, and deployment gates used before release. If you find gaps, update project-owned CLARE files only and run ./clare/verify-ci.sh once."""

agent_prompts = [
    {
        'name': 'Deployment parity setup',
        'whenToUse': 'After installing or updating CLARE, especially when coverageGaps is not empty.',
        'prompt': prompt,
    }
]

readiness = {
    'detectedSurfaces': surfaces,
    'verifiedSurfaces': verified,
    'coverageGaps': gaps,
    'agentPrompts': agent_prompts,
}
(tmp / 'readiness.json').write_text(json.dumps(readiness, indent=2) + '\n')
PYREADINESS

# Write the recommended extensions to <vscode-dir>/extensions.json. Kept in its
# own function so it runs in both --json and --report modes; otherwise passing
# --apply-extensions alongside --json would be a silent no-op.
apply_recommended_extensions() {
  mkdir -p "$VSCODE_DIR"
  local extfile="$VSCODE_DIR/extensions.json"
  if [[ -f "$extfile" ]]; then
    echo "Backing up existing $extfile -> $extfile.bak" >&2
    cp "$extfile" "$extfile.bak"
  fi
  EXTFILE="$extfile" RECOMMENDED="$TMPDIR/recommended_extensions.json" python3 - <<'PY'
import json, os, sys
extfile = os.environ['EXTFILE']
rec = json.load(open(os.environ['RECOMMENDED']))
with open(extfile, 'w') as f:
    json.dump({'recommendations': [r['extension'] for r in rec]}, f, indent=2)
print('Wrote', extfile, file=sys.stderr)
PY
}

# 6) Emit results
if [[ "$APPLY_EXT" == true ]]; then
  apply_recommended_extensions
fi

if [[ "$MODE" == "json" ]]; then
  TMPDIR="$TMPDIR" python3 - <<'PY'
import json,os
tmp=os.environ['TMPDIR']
with open(os.path.join(tmp,'fileCounts.json')) as f:
  fileCounts=json.load(f)
configs=[]
configs_path=os.path.join(tmp,'configs.txt')
if os.path.exists(configs_path):
  with open(configs_path) as f:
    configs=[l.strip() for l in f if l.strip()]
verifyTools=[]
verify_path=os.path.join(tmp,'verifyTools.jsonl')
if os.path.exists(verify_path):
  for line in open(verify_path):
    try:
      verifyTools.append(json.loads(line))
    except Exception:
      pass
recommended=json.load(open(os.path.join(tmp,'recommended_extensions.json')))
readiness_path=os.path.join(tmp,'readiness.json')
readiness={'detectedSurfaces': [], 'verifiedSurfaces': [], 'coverageGaps': [], 'agentPrompts': []}
if os.path.exists(readiness_path):
  with open(readiness_path) as f:
    readiness=json.load(f)
out={'fileCounts': fileCounts, 'configsFound': configs, 'verifyTools': verifyTools, 'recommendedExtensions': recommended, **readiness}
print(json.dumps(out, indent=2))
PY
  exit 0
fi

# Human readable report
echo "CLARE environment scan for: $PROJECT_ROOT"
echo ""
echo "File counts (by extension):"
TMPDIR="$TMPDIR" python3 - <<'PY'
import json, os
counts=json.load(open(os.path.join(os.environ['TMPDIR'],'fileCounts.json')))
print('\n'.join([f"  {k}: {v}" for k,v in counts.items()]))
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
  TMPDIR="$TMPDIR" python3 - <<'PY'
import json, os
for line in open(os.path.join(os.environ['TMPDIR'],'verifyTools.jsonl')):
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
echo "CLARE readiness surfaces:"
TMPDIR="$TMPDIR" python3 - <<'PY'
import json, os
path=os.path.join(os.environ['TMPDIR'],'readiness.json')
readiness=json.load(open(path)) if os.path.exists(path) else {'detectedSurfaces': [], 'coverageGaps': []}
print(f"  detected: {len(readiness.get('detectedSurfaces', []))}")
print(f"  likely gaps: {len(readiness.get('coverageGaps', []))}")
for item in readiness.get('coverageGaps', [])[:8]:
  cmd=f" -> {item.get('command')}" if item.get('command') else ''
  print(f"  - [{item.get('kind')}] {item.get('name')} ({item.get('path')}){cmd}")
if len(readiness.get('coverageGaps', [])) > 8:
  print(f"  ... {len(readiness.get('coverageGaps', [])) - 8} more")
PY

echo ""
echo "Agent prompt:"
TMPDIR="$TMPDIR" python3 - <<'PY'
import json, os
path=os.path.join(os.environ['TMPDIR'],'readiness.json')
readiness=json.load(open(path)) if os.path.exists(path) else {'agentPrompts': []}
prompts=readiness.get('agentPrompts') or []
if prompts:
  print('  ' + prompts[0]['prompt'])
else:
  print('  No agent prompt generated.')
PY

echo ""
echo "Recommended VS Code extensions:"
TMPDIR="$TMPDIR" python3 - <<'PY'
import json, os
for e in json.load(open(os.path.join(os.environ['TMPDIR'],'recommended_extensions.json'))):
  print(f"  - {e['extension']}: {e['reason']}")
PY

exit 0
