# repo-guard

`repo-guard` bootstraps a repository with repo-local security defaults and local `pre-commit` hooks. It also has a `run` subcommand for local Python and container audits that does not mutate the target repo.

The project is aimed at multi-agent and local-first development workflows:

- install repo-level security guidance in `AGENTS.md`
- add ignore rules for secret-bearing paths and generated report output
- assemble a local-only `.pre-commit-config.yaml` from base and language-specific fragments
- document the expected local toolchain in `LOCAL_TOOLING.md`
- provide a machine-readable runtime scan path with `repo-guard run --json`

Reruns are idempotent. `repo-guard` appends only missing lines to ignore files and uses marker comments to manage the `repo-guard` sections in `.pre-commit-config.yaml`.

## Quick Start

Bootstrap the current repo with base hooks only:

```sh
bin/repo-guard
```

Bootstrap a repo with explicit language hooks:

```sh
bin/repo-guard --langs python,typescript ~/src/my-repo
```

Detect languages from an existing repo and merge them with explicit selections:

```sh
bin/repo-guard --detect --langs containers ~/src/existing-repo
```

Run local runtime scans without writing any files:

```sh
bin/repo-guard run
bin/repo-guard run --json
bin/repo-guard run --json --deep ~/src/my-service
```

If `repo-path` is omitted in either mode, the current working directory is used.

## Command Reference

### Bootstrap Mode

Usage:

```sh
bin/repo-guard [options] [repo-path]
```

This is the default mode. It writes or updates repo files, merges `repo-guard` hook fragments into `.pre-commit-config.yaml`, checks local tooling, and optionally installs missing tools.

Options:

| Option | Meaning |
| --- | --- |
| `--langs <csv>` | Explicitly select one or more supported languages, for example `python,typescript`. |
| `--detect` | Detect supported languages from files already in the repo and merge them with `--langs`. |
| `--yes` | Automatically install missing tools when the platform/package-manager path supports it. |
| `--prompt-install` | Prompt before installing missing tools in an interactive shell. |
| `--no-install` | Report missing tools without installing them. This is the default. |
| `--dry-run` | Print the planned file changes and installs without writing anything. |
| `--check-tools` | Report the required tools and their installed versions, then exit without changing the repo. |
| `--git-init` | Run `git init` if the target repo does not already have a `.git` directory. |
| `--upgrade` | Replace existing `repo-guard` managed pre-commit blocks with the current templates. |
| `--help`, `-h` | Show CLI help and exit. |

Bootstrap mode behavior:

- If `repo-path` does not exist, bootstrap mode creates it unless `--dry-run` or `--check-tools` is active.
- If you do not pass `--langs`, `--detect`, or `--upgrade`, `repo-guard` installs the base files and base hooks only.
- `--detect` respects normal ignore boundaries because it uses `rg --files`.
- `--upgrade` only refreshes `repo-guard` managed blocks that are already marked in `.pre-commit-config.yaml`.
- `--check-tools` exits `1` when a required tool is missing or below the minimum tested version; otherwise it exits `0`.
- `--check-tools` also accepts a shorthand language CSV immediately after the flag, for example `bin/repo-guard --check-tools python,containers`.

Examples:

```sh
bin/repo-guard ~/src/my-repo
bin/repo-guard --langs python,go ~/src/service
bin/repo-guard --langs js,ts --no-install ~/src/webapp
bin/repo-guard --langs python --dry-run ~/src/my-repo
bin/repo-guard --detect ~/src/existing-repo
bin/repo-guard --detect --langs python ~/src/existing-repo
bin/repo-guard --langs python --git-init ~/src/new-repo
bin/repo-guard --langs python,typescript --upgrade ~/src/existing-repo
bin/repo-guard --check-tools --langs containers
bin/repo-guard --check-tools python,containers
```

### Runtime Scan Mode

Usage:

```sh
bin/repo-guard run [--json] [--deep] [repo-path]
```

`run` detects the repo type the same way `--detect` does, but it does not write or update files in the target repo.

Options:

| Option | Meaning |
| --- | --- |
| `--json` | Emit one normalized JSON object to stdout. |
| `--deep` | Add a local `podman build` plus `trivy image` scan when a `Dockerfile` or `Containerfile` exists. |
| `--help`, `-h` | Show CLI help and exit. |

Runtime scan behavior:

- `python3` and `rg` are required for `run`.
- Python checks only run when `requirements.txt` or `pyproject.toml` exists.
- Container checks run when the repo looks like a container repo, including `Dockerfile`, `Containerfile`, `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, or `compose.yaml`.
- `--deep` only tries to build an image when a `Dockerfile` or `Containerfile` exists. A compose-only repo still gets `trivy fs` and `trivy config`, but not the image-build/image-scan path.
- In text mode, `run` exits `0` for a clean or skipped scan and `1` for findings or scanner errors.
- In JSON mode, the normalized top-level status is:
  - `clean`: at least one applicable check ran and no unsuppressed findings remain
  - `issues`: one or more checks found unsuppressed findings
  - `error`: a required applicable tool was missing, a scanner failed, or normalized output could not be trusted
  - `skipped`: nothing applicable ran
- In JSON mode, the process exits `0` for `clean` or `skipped`, and `1` for `issues` or `error`.

Examples:

```sh
bin/repo-guard run
bin/repo-guard run ~/src/service
bin/repo-guard run --json ~/src/service
bin/repo-guard run --deep ~/src/service
bin/repo-guard run --json --deep ~/src/service
```

## JSON Output

`repo-guard run --json` emits one normalized object. The current shape is:

```json
{
  "repo": {
    "name": "my-repo",
    "path": "/abs/path/to/my-repo",
    "relative_path": "."
  },
  "status": "clean",
  "detected": ["python", "containers"],
  "missing_tools": [],
  "warnings": [],
  "checks": [
    {
      "id": "pip-audit",
      "status": "clean",
      "finding_count": 1,
      "unsuppressed_count": 0,
      "suppressed_count": 1,
      "new_count": 0,
      "known_count": 0,
      "resolved_count": 0,
      "warnings": [],
      "findings": [
        {
          "finding_key": "pip-audit|PYSEC-2026-42|flask",
          "id": "PYSEC-2026-42",
          "package": "flask",
          "severity": "UNKNOWN",
          "suppressed": true
        }
      ],
      "resolved_findings": []
    }
  ]
}
```

Current check IDs are:

- `pip-audit`
- `trivy-fs`
- `trivy-config`
- `podman-build`
- `trivy-image`

Each check gets its own normalized status:

- `clean`
- `issues`
- `error`
- `skipped`

## Repo-Local Runtime Config

`repo-guard run` reads `TARGET/.repo-guard.yaml` when present.

This parser intentionally supports a small, predictable YAML subset rather than full YAML:

- top-level keys must use the supported shape
- indentation must be 2-space based
- quoted and unquoted scalars are accepted
- inline string lists such as `["trivy", "pip-audit"]` are accepted
- invalid shapes fail with a readable error instead of a Python traceback

Example:

```yaml
version: 1
audit:
  output_dir: ".repo-guard/reports"
  deep: false
scanning:
  severity: "CRITICAL"
  image_name: "local/custom:dev"
suppressions:
  - id: "PYSEC-2026-42"
    tools: ["pip-audit"]
    package: "flask"
    reason: "accepted until upstream ships a fix"
  - id: "AVD-DS-0001"
    tools: ["trivy"]
    reason: "accepted in local dev image"
    expires: "2026-05-01"
```

Supported keys:

| Key | Type | Current meaning |
| --- | --- | --- |
| `version` | integer | Required. Must be `1`. |
| `audit.exclude` | list of strings | Accepted and validated for the broader audit/report model. Not currently consumed by `bin/repo-guard run`. |
| `audit.output_dir` | string | Accepted and validated. Default is `.repo-guard/reports`. Not currently consumed by `bin/repo-guard run`. |
| `audit.deep` | boolean | Accepted and validated. Not currently consumed by `bin/repo-guard run`. |
| `audit.baseline_file` | string or `null` | Accepted and validated. Not currently consumed by `bin/repo-guard run`. |
| `scanning.severity` | string | Passed to Trivy `--severity`. Default is `"HIGH,CRITICAL"`. |
| `scanning.image_name` | string | Used as the local image tag for `podman build` and `trivy image`. Default is `"local/repo-guard:dev"`. |
| `suppressions` | list of mappings | Suppresses normalized findings in `run --json`. |

Suppression fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Required to match a finding ID. |
| `reason` | string | Required for the suppression to apply. |
| `tools` | string or list of strings | Optional tool filter. Use exact check IDs such as `pip-audit` or `trivy-config`, or use `trivy` to match the whole Trivy family. |
| `package` | string | Optional exact package or target filter. |
| `expires` | string | Optional ISO date. Expired suppressions are ignored and reported as warnings. |

Unknown keys are tolerated and surfaced as warnings in the normalized JSON flow. Invalid types fail closed.

## Supported Languages

Supported language names:

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

## Required Local Tools

Base toolchain used by bootstrap mode:

- `pre-commit`
- `rg`
- `gitleaks`

Language-specific tool additions:

| Language | Required tools |
| --- | --- |
| `python` | `ruff`, `bandit`, `radon`, `vulture`, `pip-audit` |
| `go` | `go`, `goimports`, `golangci-lint`, `govulncheck` |
| `bash` | `shfmt`, `shellcheck`, `bash` |
| `rust` | `cargo`, `cargo-audit` |
| `c` | `cppcheck` |
| `javascript` | `eslint`, `prettier` |
| `typescript` | `eslint`, `prettier`, `tsc` |
| `ansible` | `yamllint`, `ansible-lint`, `djlint` |
| `containers` | `trivy` |

`podman` is only needed for `bin/repo-guard run --deep` when a buildable container file exists.

The minimum tested versions live in [`templates/repo-guard/LOCAL_TOOLING.md`](templates/repo-guard/LOCAL_TOOLING.md), and `--check-tools` prints them alongside the installed versions it finds.

## Detection Rules

`--detect` and `run` share the same repo-type detection rules.

Current heuristics:

- Python: `*.py`, `pyproject.toml`, `setup.py`, `setup.cfg`, `Pipfile`, `tox.ini`, `requirements*.txt`
- Go: `*.go`, `go.mod`, `go.sum`
- Bash: `*.sh`, `.shellcheckrc`, `.bashrc`, `.bash_profile`, `.bash_aliases`
- Rust: `*.rs`, `Cargo.toml`, `Cargo.lock`
- C/C++: `*.c`, `*.cc`, `*.cpp`, `*.cxx`, `*.h`, `*.hh`, `*.hpp`, `CMakeLists.txt`, `meson.build`, `compile_commands.json`
- JavaScript: `*.js`, `*.jsx`, `package.json`
- TypeScript: `*.ts`, `*.tsx`, `*.mts`, `*.cts`, `tsconfig.json`
- Ansible: `ansible.cfg`, `*.j2`, `*.jinja2`, and common paths such as `playbooks/**`, `roles/**`, `group_vars/**`, `host_vars/**`, `inventories/**`
- Containers: `Dockerfile`, `Containerfile`, `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`

Detection uses `rg --files`, so normal ignore rules still apply.

## Files Installed or Updated

Bootstrap mode copies or merges these repo-local files:

- [`templates/repo-guard/AGENTS.md`](templates/repo-guard/AGENTS.md)
- [`templates/repo-guard/LOCAL_TOOLING.md`](templates/repo-guard/LOCAL_TOOLING.md)
- [`templates/repo-guard/renovate.json`](templates/repo-guard/renovate.json)
- [`templates/repo-guard/.ignore`](templates/repo-guard/.ignore)
- [`templates/repo-guard/.rgignore`](templates/repo-guard/.rgignore)
- [`templates/repo-guard/.gitignore`](templates/repo-guard/.gitignore)
- [`templates/repo-guard/pre-commit`](templates/repo-guard/pre-commit) fragments into `.pre-commit-config.yaml`

Important file behavior:

- `AGENTS.md` is installed as the security-first repo-level instruction file.
- If a repo already has a non-`repo-guard` `AGENTS.md`, that file is preserved as `AGENTS_renamed.md` (or a numbered variant), and the new `AGENTS.md` points back to it.
- `.ignore`, `.rgignore`, and `.gitignore` get only missing lines appended.
- The default ignore templates include `.repo-guard/reports/`.
- Generated policy/config files are set to mode `0600`.
- If the target repo already has `.git` and `pre-commit` is installed, bootstrap mode runs `pre-commit install`.

Base hooks currently include:

- risky filename detection for likely secret-bearing files
- merge conflict marker detection
- trailing whitespace detection
- private key marker detection
- `gitleaks` over staged changes

Language fragments currently add:

- Python: `ruff`, `bandit`, `radon`, `vulture`, `pip-audit`
- Go: `gofmt`, `goimports`, `go vet`, `golangci-lint`, `govulncheck`
- Bash: `shfmt`, `shellcheck`, `bash -n`
- Rust: `cargo fmt`, `cargo clippy`, `cargo audit`
- C/C++: `cppcheck`, with `clang-format` and `clang-tidy` when installed
- JavaScript: local-or-global `eslint` and `prettier`
- TypeScript: local-or-global `eslint`, `prettier`, and `tsc`
- Ansible: `yamllint`, `ansible-lint`, and `djlint`
- Containers: `trivy fs` and `trivy config`

## Tool Installation Behavior

Bootstrap mode can install missing tools, but only when you opt in:

- default: report missing tools, do not install
- `--yes`: install missing tools automatically when supported
- `--prompt-install`: ask before installing in an interactive shell
- `--no-install`: keep the default explicit in scripts and automation

Automatic installation currently targets:

- macOS via `brew`
- Linux via `apt`
- Linux via `dnf`
- Linux via `pacman`

Some tools still require manual installation on some platforms. `repo-guard` prints those cases explicitly instead of guessing.

When a repo-local or active environment exists, generated hooks prefer those tools first:

- Python hooks prefer `$VIRTUAL_ENV/bin`, then `./.venv/bin`, then `./venv/bin`
- JavaScript and TypeScript hooks prefer `./node_modules/.bin`

## Shell Alias

If you want `repo-guard` on your shell path without installing it system-wide:

```sh
echo 'alias repo-guard="$HOME/git/repo-guard/bin/repo-guard"' >> ~/.zshrc
echo 'alias repo-guard="$HOME/git/repo-guard/bin/repo-guard"' >> ~/.bashrc
```

After reloading your shell:

```sh
repo-guard --langs python,typescript ~/src/my-repo
repo-guard run --json --deep ~/src/my-service
```

## Repository Layout

- [`bin/repo-guard`](bin/repo-guard): main CLI
- [`bin/repo_guard_runtime.py`](bin/repo_guard_runtime.py): config parsing and normalized runtime result builder
- [`templates/repo-guard`](templates/repo-guard): repo-local files installed by bootstrap mode
- [`templates/repo-guard/pre-commit`](templates/repo-guard/pre-commit): language-specific hook fragments

## Verification

Current repository checks include:

- [`tests/smoke.sh`](tests/smoke.sh) for CLI help, dry-run behavior, git init, and idempotent reruns
- [`tests/detect.sh`](tests/detect.sh) for repo detection
- [`tests/language-matrix.sh`](tests/language-matrix.sh) for supported languages and aliases
- [`tests/install-python-cli.sh`](tests/install-python-cli.sh) for Python CLI install behavior
- [`tests/run.sh`](tests/run.sh) for `run`, `run --json`, config parsing, suppression handling, and `run --deep`

Useful manual checks:

```sh
bin/repo-guard --check-tools --langs python
bin/repo-guard --check-tools --langs containers
bin/repo-guard run
bin/repo-guard run --json
bin/repo-guard run --deep
bin/repo-guard run --json --deep
```
