# Repo-Guard Audit, Config, and Structured Output Design

**Status:** Ready for user review

## Goal

Extend `repo-guard` with:

- `repo-guard audit [root]` for local sweeps across many repos
- layered `.repo-guard.yaml` configuration
- structured JSON output for automation
- repo-level suppressions for normalized findings
- baseline comparison for audit runs using prior JSON results

The design must fit the existing shell-first, local-first shape of `repo-guard`. It should build on the current `run` implementation rather than introducing a new service, daemon, or rewrite.

## Selected Approach

Use the existing Bash CLI as the single execution entrypoint and add one new command, `audit`, plus a small config/output layer shared by `run` and `audit`.

This phase optimizes for local sweeps under a parent directory like `~/repos`:

- repo discovery is automatic under the audit root
- exclusions come from a root `.repo-guard.yaml`
- scanned repos are never modified, fetched, or pulled
- output is dual-mode by default:
  - terminal summary for the human running the sweep
  - per-repo text logs plus one aggregate JSON summary for later tooling

This keeps the UX aligned with the current tool while making later automation possible.

## Non-Goals

This phase does not include:

- `repo-guard watch`
- dashboards or HTML reports
- alerts, notifications, or background jobs
- remote repo access or Git updates during audit
- plugin architecture for alternate scanners
- a full policy engine beyond suppressions and baseline comparison

## Command Surface

### `repo-guard run`

Current behavior stays the default:

```sh
repo-guard run [--deep] [repo-path]
```

Add one new optional output mode:

```sh
repo-guard run --json [--deep] [repo-path]
```

Behavior:

- text mode remains the default for interactive use
- `--json` emits one normalized result object to stdout
- in `--json` mode, stdout is reserved for JSON only
- scanner stdout/stderr is captured by `repo-guard` so JSON consumers do not need to strip human text
- `--deep` retains the current meaning for container repos
- `repo-path` remains positional; no new `--path` flag is introduced

`run` remains repo-local. It does not write logs or reports unless the caller redirects output.

### `repo-guard audit`

Add:

```sh
repo-guard audit [root]
repo-guard audit --deep [root]
repo-guard audit --output DIR [root]
```

Behavior:

- `root` defaults to the current working directory
- repo discovery is automatic under `root`
- `--deep` overrides config and enables deep container scans for eligible repos
- `--output DIR` overrides configured output location
- relative `--output DIR` paths are resolved from the caller's current working directory
- default output remains human-readable in the terminal, but the command also writes:
  - one text log per repo
  - one aggregate JSON summary

No `--json-only` flag is added in this phase. The default audit behavior is intentionally dual-mode.

## Configuration Model

Configuration lives in `.repo-guard.yaml`.

Two config scopes are supported:

- root config at the audit root
- optional per-repo config inside each scanned repo

Precedence:

1. CLI flags
2. per-repo `.repo-guard.yaml`
3. root `.repo-guard.yaml`
4. built-in defaults

### Config Loading By Command

- `run` loads only the target repo's `.repo-guard.yaml`, then falls back to built-in defaults
- `run` does not walk parent directories looking for a root sweep config
- `audit` loads `<root>/.repo-guard.yaml` once, then overlays `<repo>/.repo-guard.yaml` for each discovered repo
- suppressions are honored by both `run` and `audit` when a repo-local config is present

### Root Config Responsibilities

The root config controls sweep-wide behavior:

- repo discovery exclusions
- output directory
- default deep-scan behavior for audit
- default scan severity
- optional baseline file path

Example:

```yaml
version: 1

audit:
  exclude:
    - "archive/**"
    - "scratch/**"
  output_dir: ".repo-guard/reports"
  deep: false
  baseline_file: ".repo-guard/reports/audit-summary.previous.json"

scanning:
  severity: "HIGH,CRITICAL"
  image_name: "local/repo-guard:dev"
```

Path rules:

- `audit.output_dir` is resolved relative to the audit root when it is not absolute
- `audit.baseline_file` is resolved relative to the audit root when it is not absolute

### Per-Repo Config Responsibilities

Per-repo config controls repo-local scanning behavior:

- severity override
- image name override
- suppressions

Example:

```yaml
version: 1

scanning:
  severity: "CRITICAL"
  image_name: "local/my-service:dev"

suppressions:
  - id: "CVE-2025-12345"
    tools: ["trivy"]
    reason: "Base image issue accepted until next image refresh"
    expires: "2026-06-30"
  - id: "PYSEC-2026-42"
    tools: ["pip-audit"]
    package: "example-lib"
    reason: "Not reachable in deployed path"
```

### Schema Rules

- `version` is required and starts at `1`
- unknown top-level keys are warnings in v1, not fatal errors
- invalid config that prevents safe interpretation is a command error
- malformed YAML or wrong value types are fatal config errors
- root config must not allow repos outside the selected audit root
- `scanning.severity` only affects scanners that support severity filtering
- `scanning.image_name` only affects deep container image builds/scans

## Repo Discovery and Sweep Behavior

`audit` walks the selected root recursively and identifies repos by the presence of a `.git` directory or file.

Discovery rules:

- path matching is relative to the selected audit root
- exclude patterns are root-relative globs; v1 supports literal path segments plus `*` and `**`
- excluded paths are skipped before repo execution
- nested repos are allowed if they are independently discoverable and not excluded
- repos are scanned in deterministic lexicographic order by relative path

Audit rules:

- never run `git fetch`, `git pull`, or checkout operations
- never mutate scanned repos
- do not require the repo to have been bootstrapped by `repo-guard`
- use the same ecosystem detection logic already used by `run` and `--detect`

If a repo has no detected supported ecosystems:

- it still appears in the JSON summary
- it is marked `status: "skipped"`
- its log records that no supported ecosystems were detected

## Structured Output Model

`run --json` and `audit` use the same normalized result shape.

Allowed normalized statuses in v1:

- repo status: `clean`, `issues`, `error`, `skipped`
- check status: `clean`, `issues`, `error`, `skipped`

Shape notes:

- `log_path` is audit-only and is omitted in `run --json`
- baseline-related count fields default to `0` when no baseline file is active
- `baseline_state` is omitted on findings when no baseline file is active

### Per-Repo Result Shape

```json
{
  "repo": {
    "name": "my-service",
    "path": "/Users/cass/repos/my-service",
    "relative_path": "my-service"
  },
  "status": "issues",
  "detected": ["python", "containers"],
  "missing_tools": [],
  "checks": [
    {
      "id": "pip-audit",
      "status": "issues",
      "finding_count": 2,
      "unsuppressed_count": 1,
      "suppressed_count": 1,
      "new_count": 1,
      "known_count": 1,
      "resolved_count": 0,
      "log_path": "logs/my-service.log",
      "findings": [
        {
          "finding_key": "pip-audit|PYSEC-2026-42|example-lib",
          "id": "PYSEC-2026-42",
          "package": "example-lib",
          "severity": "HIGH",
          "suppressed": true,
          "baseline_state": "known"
        },
        {
          "finding_key": "pip-audit|PYSEC-2026-88|other-lib",
          "id": "PYSEC-2026-88",
          "package": "other-lib",
          "severity": "CRITICAL",
          "suppressed": false,
          "baseline_state": "new"
        }
      ],
      "resolved_findings": []
    }
  ]
}
```

### Audit Summary Shape

```json
{
  "version": 1,
  "root": "/Users/cass/repos",
  "generated_at": "2026-04-09T12:00:00Z",
  "output_dir": "/Users/cass/repos/.repo-guard/reports",
  "counts": {
    "repos_total": 12,
    "repos_clean": 8,
    "repos_with_issues": 3,
    "repos_with_errors": 1,
    "repos_skipped": 0
  },
  "repos": []
}
```

Summary rules:

- `repos` contains the full per-repo result objects
- `log_path` is relative to `output_dir`
- log filenames are derived from `repo.relative_path` with path separators replaced so collisions are deterministic
- `run --json` writes the per-repo object only; `audit` writes the aggregate summary

### Text Output

Audit writes:

- `logs/<sanitized-repo-identifier>.log` for each repo
- `audit-summary.json` as the aggregate machine-readable artifact

The terminal output shows only a concise summary:

- total repos scanned
- clean / issues / errors / skipped counts
- a short list of repos with issues or errors
- the output directory path

## Finding Normalization

Suppressions and baseline comparison require stable finding keys.

In this phase, normalization is only guaranteed for the checks `repo-guard` itself runs:

- `pip-audit`
- `trivy fs`
- `trivy config`
- `trivy image`

For normalized findings, `repo-guard` stores:

- tool/check ID
- finding ID (for example CVE/PYSEC-style identifier)
- package or target when present
- severity when present
- a stable `finding_key`

Recommended `finding_key` shape:

```text
<tool>|<finding-id>|<package-or-target>
```

The goal is stable comparison, not full fidelity to every scanner field.

## Suppressions

Suppressions are repo-local and config-driven.

Rules:

- only normalized findings can be suppressed
- `id` is required
- `reason` is required
- `tools` is optional
- `package` is optional
- `expires` is optional

Matching behavior:

- if only `id` is set, suppression applies to all findings with that ID
- if `tools` is set, it only applies to those tools
- if `package` is set, it narrows matching further
- expired suppressions are ignored and surfaced as warnings in text and JSON output

Suppressed findings:

- do not count as unsuppressed issues
- remain visible in JSON/text output with `suppressed: true`
- increment `suppressed_count`

This keeps exceptions explicit without hiding them.

## Baseline Comparison

Baseline comparison is audit-focused in this phase.

The baseline source is a prior aggregate JSON summary, usually from:

```text
<output_dir>/audit-summary.previous.json
```

Behavior:

- if `audit.baseline_file` exists, load it before the sweep
- compare normalized finding keys at `repo.relative_path + check.id + finding_key` granularity
- current findings are annotated as:
  - `new`
  - `known`
- findings present in the baseline but absent in the current run are emitted in `resolved_findings`

Baseline comparison is informational in this phase:

- it enriches JSON output and terminal summary
- it does not replace suppressions
- it does not automatically alter exit codes beyond the normal issue/error logic
- it does not automatically promote the latest summary to become the next baseline file

This gives users change detection without introducing a separate baseline-management command yet.

## Exit Semantics

### `run`

Preserve current semantics:

- `0` when all executed checks are clean or skipped
- `1` when any executed check reports unsuppressed issues or scanner errors

### `audit`

- `0` when all scanned repos are clean or skipped
- `1` when any repo has unsuppressed issues or scanner errors
- `2` for repo-guard configuration or internal failures that prevent a valid sweep

## Internal Design Constraints

Implementation should stay incremental:

- keep `bin/repo-guard` as the main executable in this phase
- share a single result-building path between `run --json` and `audit`
- preserve current text-mode `run` behavior as much as possible
- avoid introducing a plugin system

The output model should be rich enough that a future refactor into smaller internal units is straightforward, but that refactor is not part of this phase.

## Testing Strategy

Add shell tests for:

- audit repo discovery under a parent directory
- root-level excludes from `.repo-guard.yaml`
- per-repo config override precedence
- `run` loading repo-local config without inheriting parent configs
- `run --json` schema shape
- `run --json` reserving stdout for valid JSON only
- audit aggregate JSON summary shape
- suppression application and expired suppression handling
- baseline comparison showing `new` vs `known`
- baseline comparison emitting `resolved_findings`
- audit logs written to the configured output directory
- non-mutation of scanned repos

Use stub CLIs for:

- `pip-audit`
- `trivy`
- `podman`

This matches the current testing style and avoids coupling tests to real scanner installations.

## Risks and Trade-Offs

- Bash is workable here, but structured output and config parsing will increase script complexity.
- Suppression support is only as good as finding normalization. Keep the normalized schema intentionally small.
- Automatic repo discovery is the right local default, but exclusion handling must be predictable and well tested.

These trade-offs are acceptable because they unlock the three requested improvements without rewriting the tool.

## Follow-On Work

Once this design ships and is stable, the next likely steps are:

- `repo-guard watch`
- alerting/report sinks driven by the JSON summary
- generated hooks delegating to `repo-guard run`
- a future internal split of `bin/repo-guard` into smaller runner/config/output modules
