# Audit, Config, and Structured Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `repo-guard audit`, layered `.repo-guard.yaml`, `run --json`, repo-local suppressions, baseline comparison, and default ignored report artifacts without mutating scanned repos.

**Architecture:** Keep `bin/repo-guard` as the orchestrator. Add one small Python 3 standard-library helper in `bin/repo_guard_runtime.py` to handle the bounded YAML subset, finding normalization, suppressions, baseline comparison, and JSON rendering; keep Bash focused on command parsing, repo discovery, scanner invocation, log capture, and file writes. Extend the existing shell-test style with stub scanner JSON so `run --json` and `audit` are both covered end-to-end.

**Tech Stack:** Bash, Python 3 standard library, ripgrep, pip-audit, Trivy, Podman, shell tests

---

## File Map

- `bin/repo-guard`
  - Keep as the main entrypoint.
  - Add `run --json`, `audit`, `--output`, runtime config loading, audit repo discovery, log/report writing, and exit-code mapping.
  - Reuse one internal result-building path for `run --json` and `audit`.
- `bin/repo_guard_runtime.py`
  - New helper module invoked via `python3 "$script_dir/repo_guard_runtime.py" ...`.
  - Parse the v1 `.repo-guard.yaml` subset without third-party dependencies.
  - Merge configs, normalize scanner JSON, apply suppressions, compare baselines, and emit final JSON documents.
- `tests/run.sh`
  - Extend from command-log assertions to fixture-driven JSON assertions for `run --json`, repo-local config loading, suppressions, severity override, and deep image-name override.
- `tests/audit.sh`
  - New end-to-end audit coverage for repo discovery, excludes, output files, sorted order, non-mutation, baseline comparison, and audit exit codes.
- `tests/smoke.sh`
  - Add coverage for default report ignore lines and help text for the new command surface.
- `templates/repo-guard/.gitignore`
  - Add `/.repo-guard/reports/`.
- `templates/repo-guard/.ignore`
  - Add `/.repo-guard/reports/`.
- `templates/repo-guard/.rgignore`
  - Add `/.repo-guard/reports/`.
- `README.md`
  - Document `run --json`, `audit`, config precedence, suppressions, baseline behavior, output files, exit semantics, and the default ignored reports directory.

## Implementation Notes

- Use a bounded parser, not a generic YAML engine. The only supported shape in v1 is:
  - top-level scalars: `version`
  - top-level mappings: `audit`, `scanning`
  - `audit.exclude` as a list of strings
  - `suppressions` as a list of mappings with scalar fields plus optional inline string arrays for `tools`
- For `run --json`, set `repo.relative_path` to `"."` so the shared shape stays deterministic even without an audit root.
- Add `warnings: []` arrays to repo/check JSON objects. Use those arrays to surface expired suppressions and unknown top-level config keys because the spec requires warnings in JSON but does not yet pin the field name.
- Treat malformed config or internal processing failures as audit exit code `2`; keep `run` on the existing `0/1` model.

### Task 1: Add Default Report Ignores

**Files:**
- Modify: `tests/smoke.sh`
- Modify: `templates/repo-guard/.gitignore`
- Modify: `templates/repo-guard/.ignore`
- Modify: `templates/repo-guard/.rgignore`

- [ ] **Step 1: Extend `tests/smoke.sh` with failing assertions for ignore defaults**

```bash
grep -Fqx "/.repo-guard/reports/" "$target_repo/.gitignore"
grep -Fqx "/.repo-guard/reports/" "$target_repo/.ignore"
grep -Fqx "/.repo-guard/reports/" "$target_repo/.rgignore"
```

- [ ] **Step 2: Run the smoke test to verify it fails first**

Run: `bash tests/smoke.sh`
Expected: FAIL on missing `/.repo-guard/reports/` lines.

- [ ] **Step 3: Add the default ignore line to all three templates**

```text
/.repo-guard/reports/
```

Place it once in each hidden template near the other generated/local-artifact exclusions.

- [ ] **Step 4: Re-run the smoke test**

Run: `bash tests/smoke.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/smoke.sh \
  templates/repo-guard/.gitignore \
  templates/repo-guard/.ignore \
  templates/repo-guard/.rgignore
git commit -m "chore: ignore repo-guard audit reports by default"
```

### Task 2: Implement `run --json` with Repo-Local Config and Suppressions

**Files:**
- Create: `bin/repo_guard_runtime.py`
- Modify: `bin/repo-guard:28-58`
- Modify: `bin/repo-guard:5-27`
- Modify: `bin/repo-guard:61-83`
- Modify: `bin/repo-guard:1216-1440`
- Modify: `tests/run.sh`

- [ ] **Step 1: Turn `tests/run.sh` into a failing JSON-mode regression test**

Add JSON-producing stubs alongside the existing command-log behavior:

```bash
cat >"$stub_dir/pip-audit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_MODE:-text}" = "json" ]; then
  cat "$PIP_AUDIT_JSON"
  exit "${PIP_AUDIT_EXIT_CODE:-0}"
fi
printf 'pip-audit %s\n' "$*" >>"$RUN_LOG"
EOF

cat >"$stub_dir/trivy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_MODE:-text}" = "json" ]; then
  case "$1" in
    fs) cat "$TRIVY_FS_JSON" ;;
    config) cat "$TRIVY_CONFIG_JSON" ;;
    image) cat "$TRIVY_IMAGE_JSON" ;;
  esac
  exit "${TRIVY_EXIT_CODE:-0}"
fi
printf 'trivy %s\n' "$*" >>"$RUN_LOG"
EOF
```

Add a repo-local config fixture:

```yaml
version: 1
scanning:
  severity: "CRITICAL"
  image_name: "local/custom:dev"
suppressions:
  - id: "PYSEC-2026-42"
    tools: ["pip-audit"]
    package: "flask"
    reason: "accepted in test fixture"
```

Validate JSON output with Python:

```bash
env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  "$script" run --json "$python_repo" >"$tmp_root/run.json"

python3 - "$tmp_root/run.json" "$python_repo" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["repo"]["path"] == sys.argv[2]
assert data["repo"]["relative_path"] == "."
assert data["status"] == "issues"
check = data["checks"][0]
assert check["id"] == "pip-audit"
assert check["suppressed_count"] == 1
assert check["unsuppressed_count"] == 1
assert check["findings"][0]["suppressed"] is True
PY
```

Also assert the help text reflects the implemented `run --json` surface:

```bash
help_output="$("$script" --help)"
printf '%s\n' "$help_output" | grep -Fq 'repo-guard run [--json] [--deep] [repo-path]'
printf '%s\n' "$help_output" | grep -Fq -- '--json             emit one normalized JSON result object to stdout'
```

- [ ] **Step 2: Run the run test to verify it fails first**

Run: `bash tests/run.sh`
Expected: FAIL with `unknown option: --json` or JSON-shape assertions failing.

- [ ] **Step 3: Create `bin/repo_guard_runtime.py` with the bounded config + normalization helpers**

Start with this shape:

```python
#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CONFIG = {
    "version": 1,
    "audit": {
        "exclude": [],
        "output_dir": ".repo-guard/reports",
        "deep": False,
        "baseline_file": None,
    },
    "scanning": {
        "severity": "HIGH,CRITICAL",
        "image_name": "local/repo-guard:dev",
    },
    "suppressions": [],
}

def parse_scalar(raw: str):
    raw = raw.strip()
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw.isdigit():
        return int(raw)
    if raw.startswith("[") and raw.endswith("]"):
        items = [item.strip().strip('"') for item in raw[1:-1].split(",") if item.strip()]
        return items
    return raw.strip('"')

def finding_key(tool: str, finding_id: str, package_or_target: str | None) -> str:
    target = package_or_target or "-"
    return f"{tool}|{finding_id}|{target}"
```

Then add:

- `parse_config_file(path)`
- `merge_configs(root_config, repo_config)`
- `normalize_pip_audit(document)`
- `normalize_trivy(document, tool_id)`
- `apply_suppressions(findings, suppressions, warnings)`
- `build_repo_result(...)`

- [ ] **Step 4: Wire `bin/repo-guard` `run` mode to emit JSON-only stdout**

Add new globals near the top:

```bash
run_json=0
audit_output_dir=""
```

Add a capture helper so scanner stdout/stderr can be separated from final JSON:

```bash
capture_command_output() {
  local stdout_file=$1
  local stderr_file=$2
  shift 2

  if "$@" >"$stdout_file" 2>"$stderr_file"; then
    return 0
  fi
  return $?
}
```

In argument parsing, accept JSON only for `run`:

```bash
    --json)
      if [ "$command_name" != "run" ]; then
        log_warn "unknown option: $1"
        exit 1
      fi
      run_json=1
      shift
      ;;
```

Then update `run_command()` to:

- load only `<repo>/.repo-guard.yaml`
- pass severity/image name from merged config into scanner invocations
- call scanners in JSON mode:

```bash
pip-audit -f json -r requirements.txt
trivy fs --format json --severity "$severity" --exit-code 1 "$target"
trivy config --format json --severity "$severity" --exit-code 1 "$target"
trivy image --format json --severity "$severity" --exit-code 1 "$image_name"
```

- build the final repo object through `bin/repo_guard_runtime.py`
- print JSON to stdout only when `run_json=1`

Update `show_help()` in the same task so the documented `run --json` usage is truthful:

```text
  repo-guard run [--json] [--deep] [repo-path]
```

and:

```text
  --json             emit one normalized JSON result object to stdout
```

- [ ] **Step 5: Re-run the run test**

Run: `bash tests/run.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add bin/repo_guard_runtime.py bin/repo-guard tests/run.sh
git commit -m "feat: add structured run output with repo-local config"
```

### Task 3: Add `repo-guard audit` Discovery, Layered Config, and Report Writing

**Files:**
- Modify: `bin/repo-guard:28-58`
- Modify: `bin/repo-guard:5-27`
- Modify: `bin/repo-guard:1194-1560`
- Modify: `bin/repo_guard_runtime.py`
- Create: `tests/audit.sh`

- [ ] **Step 1: Create a failing `tests/audit.sh` end-to-end audit harness**

Set up a parent directory with multiple repos:

```bash
audit_root="$tmp_root/repos"
mkdir -p "$audit_root/alpha/.git" "$audit_root/beta/.git" "$audit_root/archive/old/.git"
printf 'flask==3.0.0\n' >"$audit_root/alpha/requirements.txt"
printf 'FROM python:3.12-slim\n' >"$audit_root/beta/Dockerfile"
printf 'FROM alpine:3.20\n' >"$audit_root/archive/old/Dockerfile"
```

Add a root config:

```yaml
version: 1
audit:
  exclude:
    - "archive/**"
  output_dir: ".repo-guard/reports"
scanning:
  severity: "HIGH,CRITICAL"
```

Add a per-repo override for `beta`:

```yaml
version: 1
scanning:
  image_name: "local/beta:dev"
```

Assert:

- only `alpha` and `beta` are in `audit-summary.json`
- repo order is `alpha`, then `beta`
- `logs/alpha.log` and `logs/beta.log` exist
- no report files are written inside the scanned repos
- no `git` command is invoked during the sweep
- help text includes `repo-guard audit [--deep] [--output DIR] [root]`
- help text includes `--output DIR       write audit logs and audit-summary.json into DIR`

Use a stub `git` that records invocations and assert the log stays empty.

- [ ] **Step 2: Run the new audit test to verify it fails first**

Run: `bash tests/audit.sh`
Expected: FAIL with `unknown option: audit` or missing output artifacts.

- [ ] **Step 3: Add audit command parsing and root/output resolution in `bin/repo-guard`**

At the top-level command dispatch, detect `audit` the same way `run` is detected now:

```bash
if [ $# -gt 0 ] && [ "$1" = "run" ]; then
  command_name="run"
  shift
elif [ $# -gt 0 ] && [ "$1" = "audit" ]; then
  command_name="audit"
  shift
fi
```

Add `--output DIR` handling only for `audit`.

Update `show_help()` in the same task so the documented audit surface is truthful:

```text
  repo-guard audit [--deep] [--output DIR] [root]
```

and:

```text
  --output DIR       write audit logs and audit-summary.json into DIR
```

- [ ] **Step 4: Implement repo discovery and per-repo execution**

Add focused helpers in `bin/repo-guard`:

```bash
discover_audit_repo_markers() {
  local root=$1
  find "$root" \( -name .git -type d -o -name .git -type f \) -print
}

run_audit_command() {
  local root=$1
  local output_dir=$2
  # discover repos, filter excludes, sort by relative path,
  # call the same internal repo-result path used by run --json
}
```

Use `bin/repo_guard_runtime.py` to:

- merge root + repo config for each repo
- filter candidate repo paths against the root-relative `audit.exclude` list
- build the aggregate summary JSON with counts and full `repos` array

- [ ] **Step 5: Write text logs and the aggregate summary**

For each repo:

- capture human-readable scanner output into `logs/<sanitized>.log`
- keep `log_path` relative to the chosen output directory
- print only a concise terminal summary after the sweep finishes

Write the aggregate JSON file to:

```text
<output_dir>/audit-summary.json
```

- [ ] **Step 6: Re-run the audit test**

Run: `bash tests/audit.sh`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add bin/repo-guard bin/repo_guard_runtime.py tests/audit.sh
git commit -m "feat: add audit sweeps with layered config"
```

### Task 4: Add Baseline Comparison, Warning Reporting, and Final Exit Semantics

**Files:**
- Modify: `bin/repo_guard_runtime.py`
- Modify: `bin/repo-guard:77-83`
- Modify: `bin/repo-guard:1306-1440`
- Modify: `tests/run.sh`
- Modify: `tests/audit.sh`

- [ ] **Step 1: Extend the run/audit tests with failing baseline and warning assertions**

In `tests/audit.sh`, create a previous summary fixture:

```json
{
  "version": 1,
  "root": "/tmp/repos",
  "generated_at": "2026-04-09T12:00:00Z",
  "output_dir": "/tmp/repos/.repo-guard/reports",
  "counts": {
    "repos_total": 1,
    "repos_clean": 0,
    "repos_with_issues": 1,
    "repos_with_errors": 0,
    "repos_skipped": 0
  },
  "repos": [
    {
      "repo": {
        "name": "alpha",
        "path": "/tmp/repos/alpha",
        "relative_path": "alpha"
      },
      "status": "issues",
      "detected": ["python"],
      "missing_tools": [],
      "checks": [
        {
          "id": "pip-audit",
          "status": "issues",
          "finding_count": 1,
          "unsuppressed_count": 1,
          "suppressed_count": 0,
          "new_count": 0,
          "known_count": 1,
          "resolved_count": 0,
          "findings": [
            {
              "finding_key": "pip-audit|PYSEC-2026-42|flask",
              "id": "PYSEC-2026-42",
              "package": "flask",
              "severity": "HIGH"
            }
          ],
          "resolved_findings": []
        }
      ]
    }
  ]
}
```

Then assert:

```bash
python3 - "$summary_json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
repo = data["repos"][0]
check = repo["checks"][0]
assert check["findings"][0]["baseline_state"] == "known"
assert check["resolved_findings"]
assert any("expired" in warning.lower() for warning in repo["warnings"])
PY
```

Make the current stub data include:

- one finding that matches the baseline key exactly, so `baseline_state == "known"`
- one baseline-only key that is absent now, so `resolved_findings` is non-empty

Also add a malformed-config case and assert:

```bash
if "$script" audit "$broken_root"; then
  echo "audit unexpectedly passed on malformed config" >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 2
```

- [ ] **Step 2: Run the updated run/audit tests to verify they fail first**

Run: `bash tests/run.sh && bash tests/audit.sh`
Expected: FAIL on missing `baseline_state`, missing `resolved_findings`, missing `warnings`, or wrong audit exit code.

- [ ] **Step 3: Extend `bin/repo_guard_runtime.py` with baseline and warning handling**

Add functions shaped like:

```python
def compare_with_baseline(current_checks, baseline_repo):
    # map baseline findings by (check_id, finding_key)
    # mark current findings as new/known
    # emit resolved_findings when a prior key is absent now

def append_warning(container: dict, message: str) -> None:
    container.setdefault("warnings", [])
    container["warnings"].append(message)
```

Use `warnings` for:

- expired suppressions
- unknown top-level config keys

- [ ] **Step 4: Finalize audit exit semantics in `bin/repo-guard`**

Keep `run` on `0` or `1`.

For `audit`:

- `0`: all repos clean or skipped
- `1`: any unsuppressed issues or scanner errors
- `2`: config parse failure, invalid baseline file, or internal audit processing failure

Map internal helper failures explicitly instead of letting `set -e` abort without a controlled exit code.

- [ ] **Step 5: Re-run the run and audit tests**

Run: `bash tests/run.sh && bash tests/audit.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add bin/repo_guard_runtime.py bin/repo-guard tests/run.sh tests/audit.sh
git commit -m "feat: add audit baseline comparison and warnings"
```

### Task 5: Update Documentation and Run the Full Regression Suite

**Files:**
- Modify: `README.md`
- Verify: `tests/smoke.sh`
- Verify: `tests/detect.sh`
- Verify: `tests/run.sh`
- Verify: `tests/audit.sh`
- Verify: `tests/install-python-cli.sh`
- Verify: `tests/language-matrix.sh`

- [ ] **Step 1: Update the README usage block and examples**

Add these examples:

```sh
bin/repo-guard run --json
bin/repo-guard audit ~/repos
bin/repo-guard audit --deep --output ./tmp/reports ~/repos
```

Document:

- config precedence: CLI -> repo config -> root config -> defaults
- `run` loads only repo-local `.repo-guard.yaml`
- `audit` loads `<root>/.repo-guard.yaml` plus per-repo overrides
- bootstrapped repos ignore `/.repo-guard/reports/` by default
- if a team wants a tracked baseline file, move `audit.baseline_file` outside the ignored reports directory

- [ ] **Step 2: Document the JSON result shape and exit codes**

Add a minimal JSON example and list:

```text
run:   0 clean/skipped, 1 issues/errors
audit: 0 clean/skipped, 1 issues/errors, 2 config/internal failure
```

- [ ] **Step 3: Run Python syntax validation for the new helper**

Run: `python3 -m py_compile bin/repo_guard_runtime.py`
Expected: PASS

- [ ] **Step 4: Run shellcheck on the Bash entrypoint**

Run: `shellcheck bin/repo-guard`
Expected: PASS

- [ ] **Step 5: Run the full shell regression suite**

Run:

```bash
bash tests/smoke.sh && \
bash tests/detect.sh && \
bash tests/run.sh && \
bash tests/audit.sh && \
bash tests/install-python-cli.sh && \
bash tests/language-matrix.sh
```

Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: document audit config and structured output"
```

## Manual Review Checklist

Use this before execution handoff:

- Confirm the plan never asks `audit` to mutate a scanned repo or invoke `git fetch` / `git pull`.
- Confirm `run --json` is the only mode that reserves stdout for JSON-only output.
- Confirm the helper remains pure standard library Python; do not introduce `PyYAML`, `jq`, or `yq`.
- Confirm the ignored path is only `/.repo-guard/reports/`, not the whole `/.repo-guard/` namespace.
- Confirm every new behavior has at least one shell test before implementation.
