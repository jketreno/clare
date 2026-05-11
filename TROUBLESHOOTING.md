# CLARE Troubleshooting

This guide covers common setup and runtime issues for CLARE, especially around optional extension tools.

## Platform Support and Assumptions

- macOS: supported
- Linux: supported
- Windows: recommended via WSL2 (Ubuntu or similar)

CLARE is Bash-first. Native Windows shells may work with extra setup, but WSL2 is the tested and recommended path.

## Quick Triage

If something fails, run these first:

```bash
./clare/verify-ci.sh
./clare/verify-ci.sh --exclude-untracked
```

Then read the first failing section and resolve that issue before moving to the next.

## Common CLARE Workflow Issues

### verify-ci.sh says a tool is missing

Symptom:

- An extension is enabled in clare/extensions.yml
- verify-ci.sh fails with "<command> not found"

Why it happens:

- The command in the extension is not installed or not on PATH.

Fix:

1. Install the tool shown in install_hint from clare/extensions.yml.
2. Confirm the executable is visible:

```bash
command -v <tool-name>
```

3. Re-run:

```bash
./clare/verify-ci.sh
```

### verify-ci.sh keeps failing after install

Symptom:

- You installed a tool, but verify-ci.sh still says not found.

Why it happens:

- The install path is not on PATH in your current shell session.

Fix:

1. Open a new shell, then verify command visibility.
2. Add the tool bin path to your shell startup file.
3. Confirm with command -v.

## Optional Extension Tool Setup and Pitfalls

### TypeScript / JavaScript complexity (eslint-complexity)

Required command:

- npx (with eslint installed in the project)

Install:

```bash
npm install --save-dev eslint
```

Common pitfalls:

- ESLint v9 requires a flat config file.
- Missing config causes errors like "couldn't find an eslint.config.* file".

Fix:

- Add one of:
  - eslint.config.js
  - eslint.config.mjs
  - eslint.config.cjs

### Go complexity (golangci-lint-complexity)

Required command:

- golangci-lint

Install:

```bash
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
```

Common pitfalls:

- Go is installed, but golangci-lint is not on PATH.
- go install places binaries in GOPATH/bin (often ~/go/bin).

Fix:

1. Check where Go installs binaries:

```bash
go env GOPATH
echo "$HOME/go/bin"
```

2. Add the bin path to PATH in your shell rc file.
3. Confirm:

```bash
command -v golangci-lint
```

Notes:

- CLARE generates a temporary config to enforce threshold for cyclop and gocognit.
- If Go code is not in scanned paths, the extension may report no matching files.

### Python complexity (complexipy-complexity)

Required command:

- complexipy

Install (preferred):

```bash
pipx install complexipy
```

Alternative (inside active Python environment):

```bash
pip install complexipy
```

Common pitfalls:

- pip install put complexipy in a different environment than CI shell.
- pipx is installed but ~/.local/bin is not on PATH.

Fix:

1. Confirm executable visibility:

```bash
command -v complexipy
```

2. If using pipx, ensure pipx path is configured:

```bash
pipx ensurepath
```

3. Restart shell and re-check command visibility.

### Bash/shell complexity (shellmetrics-complexity)

Required command:

- shellmetrics

Install:

```bash
mkdir -p "$HOME/bin"
curl -fsSL https://git.io/shellmetrics -o "$HOME/bin/shellmetrics"
chmod +x "$HOME/bin/shellmetrics"
```

Common pitfalls:

- shellmetrics installed but `$HOME/bin` is not on PATH.
- Parser shell mismatch for scripts that rely on bash-specific syntax.

Fix:

1. Confirm executable visibility:

```bash
command -v shellmetrics
```

2. Ensure `$HOME/bin` is on PATH in your shell startup file.
  - Bash:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

  - Zsh:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

  - Then confirm:

```bash
command -v shellmetrics
```
3. If needed, set extension `extra_flags` to select parser shell (example: `--shell bash`).

## macOS Setup Pitfalls

### Homebrew command not found

Fix:

- Install Homebrew first, then restart shell.
- Confirm with:

```bash
command -v brew
```

### PATH differs between Terminal and GUI apps

Symptom:

- Tools work in one terminal, fail in another app-integrated terminal.

Fix:

- Add PATH updates in your shell rc file (~/.zshrc or ~/.bashrc).
- Restart your terminal app.

## Linux Setup Pitfalls

### Minimal distro missing build tooling

Symptom:

- go install or pip tooling fails due to missing compilers or ssl headers.

Fix:

- Install your distro's base dev toolchain and Python/Go runtime packages.
- Re-run tool install.

### Multiple Python installations

Symptom:

- complexipy installed, but command not found or wrong version.

Fix:

- Prefer pipx for global CLI isolation.
- Or use a single explicit virtual environment and activate before running verify-ci.sh.

## Windows and WSL2 Pitfalls

### Running CLARE from PowerShell or cmd.exe directly

Symptom:

- Bash script behavior differs or fails.

Fix:

- Use WSL2 and run CLARE inside the Linux environment.

### WSL path mix-ups

Symptom:

- Commands run against Windows paths and fail unexpectedly.

Fix:

- Keep project and toolchain inside WSL filesystem when possible.
- Run all CLARE commands from the same WSL shell context.

## Troubleshooting Extension Scope

### Extension reports "no files matched configured paths/types"

Why it happens:

- paths, file_types, or exclude in clare/extensions.yml do not match your repo.

Fix:

1. Check extension options in clare/extensions.yml.
2. Validate target files exist under configured paths.
3. Temporarily widen scope to confirm behavior.
4. Re-tighten once matching is verified.

## If You Are Still Stuck

1. Run:

```bash
./clare/verify-ci.sh
```

2. Copy the first failing section and the command from that section.
3. Open an issue with:
   - OS and shell
   - Whether using WSL2
   - failing command output
   - relevant extension block from clare/extensions.yml
