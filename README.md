# repo-guard

`repo-guard` bootstraps a repository with secret-safe defaults and local `pre-commit` hooks, and it can run local dependency/container scans against an existing repo.

It installs or merges:

- `AGENTS.md` with security-handling rules
- `.ignore`, `.rgignore`, and `.gitignore` entries for secret-bearing files plus common OS/editor junk
- `LOCAL_TOOLING.md` documenting required local CLIs
- `renovate.json` with a host-agnostic dependency/base-image update baseline
- `.pre-commit-config.yaml` assembled from base and language-specific hook fragments

The tool is designed for multi-agent development across macOS and Linux: give CLI assistants and editor-integrated coding tools a repo-local security baseline, then add language-specific quality gates before code lands in git.

Reruns are idempotent: the script appends only missing lines and avoids duplicating pre-commit fragments by using marker comments.

## Usage

```sh
bin/repo-guard [--langs python,go,...] [--detect] [--yes|--prompt-install|--no-install] [--dry-run] [--check-tools] [--git-init] [--upgrade] [repo-path]
bin/repo-guard run [--deep] [repo-path]
```

Examples:

```sh
bin/repo-guard ~/src/my-repo
bin/repo-guard --langs python,typescript ~/src/my-repo
bin/repo-guard --langs go,rust --yes ~/src/my-repo
bin/repo-guard --langs js,ts --no-install ~/src/my-repo
bin/repo-guard --langs python,go --dry-run ~/src/my-repo
bin/repo-guard --detect ~/src/existing-repo
bin/repo-guard --detect ~/src/existing-container-repo
bin/repo-guard --detect --langs python ~/src/existing-repo
bin/repo-guard --langs python,containers ~/src/my-service
bin/repo-guard --langs rust --check-tools
bin/repo-guard --check-tools --langs containers
bin/repo-guard --detect --check-tools ~/src/existing-repo
bin/repo-guard --langs python --git-init ~/src/my-repo
bin/repo-guard --langs python,typescript --upgrade ~/src/existing-repo
bin/repo-guard run
bin/repo-guard run --deep
```

If `repo-path` is omitted, the current working directory is used in both bootstrap mode and `run` mode.

### Shell Alias

If you do not want to type the full path each time, add an alias to your shell config:

```sh
echo 'alias repo-guard="$HOME/git/repo-guard/bin/repo-guard"' >> ~/.zshrc
echo 'alias repo-guard="$HOME/git/repo-guard/bin/repo-guard"' >> ~/.bashrc
```

Reload your shell config or start a new shell session, then use:

```sh
repo-guard --langs python,typescript ~/src/my-repo
repo-guard --check-tools go
```

If you want a one-command bootstrap for new repos:

```sh
echo 'newrepo() { mkdir -p "$1" && cd "$1" && git init && repo-guard "$PWD"; }' >> ~/.zshrc
echo 'newrepo() { mkdir -p "$1" && cd "$1" && git init && repo-guard "$PWD"; }' >> ~/.bashrc
```

Important behavior changes:

- default behavior is to write repo files and report missing tools without installing them
- `--yes` enables automatic tool installation when supported
- `--prompt-install` restores interactive prompting before installation
- `--dry-run` shows planned changes without touching repo files
- `--check-tools` reports required tools and exits without changing the repo
- `--detect` scans an existing repo with normal ignore boundaries and infers supported languages from filenames and common manifests
- `--git-init` initializes a Git repository when `.git` is missing
- `--upgrade` refreshes existing `repo-guard` managed pre-commit blocks to the current templates
- `run` executes local Python/container scans without mutating the target repo
- `run --deep` is the only path that requires `podman` in this MVP

## Supported Languages

- `python`
- `go`
- `bash`
- `rust`
- `c`
- `javascript`
- `typescript`
- `ansible`
- `containers`

Aliases:

- `py` -> `python`
- `js` -> `javascript`
- `ts` -> `typescript`
- `sh`, `shell` -> `bash`
- `cpp`, `cxx` -> `c`

## Detection

`--detect` is for repos that already have code in them. It scans the target repo with `rg --files`, so normal ignore rules still apply, then adds hooks for supported ecosystems it can infer.

Current heuristics include:

- Python: `*.py`, `pyproject.toml`, `setup.py`, `setup.cfg`, `Pipfile`, `tox.ini`, `requirements*.txt`
- Go: `*.go`, `go.mod`, `go.sum`
- Bash: `*.sh`
- Rust: `*.rs`, `Cargo.toml`, `Cargo.lock`
- C/C++: `*.c`, `*.cc`, `*.cpp`, `*.cxx`, headers, `CMakeLists.txt`, `meson.build`, `compile_commands.json`
- JavaScript: `*.js`, `*.jsx`, `package.json`
- TypeScript: `*.ts`, `*.tsx`, `*.mts`, `*.cts`, `tsconfig.json`
- Ansible: `ansible.cfg`, `*.j2`, `*.jinja2`, and common paths such as `playbooks/`, `roles/`, `group_vars/`, `host_vars/`, `inventories/`
- Containers: `Dockerfile`, `Containerfile`, `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`

You can combine `--detect` with `--langs` when you want auto-detection plus an explicit override or extra language.

## What Gets Installed

### Base repo files

The script copies or merges these templates into the target repo:

- [`templates/repo-guard/AGENTS.md`](templates/repo-guard/AGENTS.md)
- [`templates/repo-guard/LOCAL_TOOLING.md`](templates/repo-guard/LOCAL_TOOLING.md)
- [`templates/repo-guard/renovate.json`](templates/repo-guard/renovate.json)
- [`templates/repo-guard/.ignore`](templates/repo-guard/.ignore)
- [`templates/repo-guard/.rgignore`](templates/repo-guard/.rgignore)
- [`templates/repo-guard/.gitignore`](templates/repo-guard/.gitignore)

`AGENTS.md` is handled more strictly than the ignore files. If the target repo already has a root `AGENTS.md` that is not already the `repo-guard` security template, `repo-guard` renames the existing file to `AGENTS_renamed.md` (or a numbered variant if needed), installs the security-first `AGENTS.md`, and adds a short note in the new file pointing back to the preserved instructions.

### Pre-commit hooks

The script ensures `.pre-commit-config.yaml` exists with a top-level `repos:` key, then appends:

- Base hooks from [`templates/repo-guard/pre-commit/base.yaml`](templates/repo-guard/pre-commit/base.yaml)
- Optional language fragments from [`templates/repo-guard/pre-commit`](templates/repo-guard/pre-commit)

Base hooks currently include:

- risky filename detection for likely secret-bearing files
- merge conflict marker detection
- trailing whitespace detection
- private key marker detection
- `gitleaks` over staged changes

Language fragments add local hooks for the selected ecosystems:

- Python: prefers tools from an active `$VIRTUAL_ENV`, then `./.venv/bin`, then `./venv/bin` for `ruff`, `bandit`, `radon`, `vulture`, `pip-audit`, then falls back to global CLIs
- Go: `gofmt`, `goimports`, `go vet`, `golangci-lint`, `govulncheck`
- Bash: `shfmt`, `shellcheck`, `bash -n`
- Rust: `cargo fmt`, `cargo clippy`, `cargo audit`
- C/C++: `cppcheck` as the baseline, with `clang-format` and `clang-tidy` used when installed
- Ansible: `yamllint` for YAML, `ansible-lint` for playbooks and roles, and `djlint` for Jinja2 templates
- JavaScript: prefers `./node_modules/.bin/eslint` and `./node_modules/.bin/prettier`, then falls back to global CLIs
- TypeScript: prefers `./node_modules/.bin/eslint`, `./node_modules/.bin/prettier`, and `./node_modules/.bin/tsc`, then falls back to global CLIs
- Containers: `trivy fs` and `trivy config` against the repo tree

## Runtime Scans

`repo-guard run` reuses the same repo detection rules as `--detect`, but it does not write or modify repo files.

- Python repos: runs `pip-audit` against `requirements.txt` or `pyproject.toml`
- Container repos: runs `trivy fs` and `trivy config`
- `run --deep`: adds `podman build` plus `trivy image`

## Tool Installation

Hooks are configured to use locally installed tools instead of downloading hook repositories.
When an active Python virtualenv or repo-local toolchain exists, the generated Python and Node hooks prefer that copy before falling back to `PATH`.

`repo-guard` always computes the required tools for the selected languages and can optionally install missing ones:

- default behavior: report missing tools but do not install them
- `--yes`: install missing tools automatically when supported
- `--prompt-install`: prompt before installing in an interactive shell
- `--no-install`: keep reporting behavior explicit in scripts and automation
- `--check-tools`: report installed versions against minimum tested baselines without pinning exact versions

Automatic installation is supported on:

- macOS via `brew`
- Linux via `apt`, `dnf`, or `pacman`

Some tools still require manual installation on some platforms. The script prints those cases explicitly.
The current minimum tested versions are documented in [`templates/repo-guard/LOCAL_TOOLING.md`](templates/repo-guard/LOCAL_TOOLING.md).
For the container/runtime flow, `trivy` is part of the normal local tool baseline and `podman` is optional unless you use `bin/repo-guard run --deep`.

## Other Side Effects

- Generated policy and config files are set to mode `0600`
- If `--git-init` is passed and `.git` is missing, the script runs `git init`
- If the target repo already has `.git` and `pre-commit` is installed, `pre-commit install` is run

## Project Layout

- [`bin/repo-guard`](bin/repo-guard): main entrypoint
- [`templates/repo-guard`](templates/repo-guard): files merged into target repos
- [`templates/repo-guard/pre-commit`](templates/repo-guard/pre-commit): hook fragments grouped by language

## Verification

The repository now includes:

- [`tests/smoke.sh`](tests/smoke.sh) for `--help`, `--dry-run`, git initialization, and idempotent reruns
- [`tests/detect.sh`](tests/detect.sh) for mixed-language detection on an existing repo
- [`tests/language-matrix.sh`](tests/language-matrix.sh) for generated config validation across every supported language plus alias coverage
- [`tests/install-python-cli.sh`](tests/install-python-cli.sh) for Python CLI install behavior
- [`tests/run.sh`](tests/run.sh) for `repo-guard run` and `run --deep` using stub CLIs

Useful manual checks are still:

- `bin/repo-guard --check-tools --langs python`
- `bin/repo-guard --check-tools --langs containers`
- `bin/repo-guard run`
- `bin/repo-guard run --deep`
- inspecting the generated files and `.pre-commit-config.yaml`
- linting [`bin/repo-guard`](bin/repo-guard) with `shellcheck` when available
