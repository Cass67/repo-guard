#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/repo-guard"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-run.XXXXXX")"
stub_dir="$tmp_root/stubs"
missing_tool_dir="$tmp_root/missing-tool-shim"
missing_rg_dir="$tmp_root/missing-rg-shim"
missing_python_dir="$tmp_root/missing-python-shim"
partial_scan_dir="$tmp_root/partial-scan-shim"
run_log="$tmp_root/run.log"
path_value="$stub_dir:$PATH"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$stub_dir"
mkdir -p "$missing_tool_dir"
mkdir -p "$missing_rg_dir"
mkdir -p "$missing_python_dir"
mkdir -p "$partial_scan_dir"
ln -s "$(command -v python3)" "$missing_tool_dir/python3"
ln -s "$(command -v python3)" "$missing_rg_dir/python3"
ln -s "$(command -v python3)" "$partial_scan_dir/python3"
cat >"$missing_python_dir/python3" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
if command -v rg >/dev/null 2>&1; then
  ln -s "$(command -v rg)" "$missing_tool_dir/rg"
  ln -s "$(command -v rg)" "$missing_python_dir/rg"
  ln -s "$(command -v rg)" "$partial_scan_dir/rg"
fi
missing_path_value="$missing_tool_dir:/usr/bin:/bin:/usr/sbin:/sbin"
missing_rg_path_value="$missing_rg_dir:/usr/bin:/bin:/usr/sbin:/sbin"
missing_python_path_value="$missing_python_dir:/usr/bin:/bin:/usr/sbin:/sbin"
partial_scan_path_value="$partial_scan_dir:/usr/bin:/bin:/usr/sbin:/sbin"

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
case "$1" in
  fs) exit "${TRIVY_FS_EXIT_CODE:-0}" ;;
  config) exit "${TRIVY_CONFIG_EXIT_CODE:-0}" ;;
  image) exit "${TRIVY_IMAGE_EXIT_CODE:-0}" ;;
esac
EOF

cat >"$stub_dir/pip-audit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_MODE:-text}" = "json" ]; then
  cat "$PIP_AUDIT_JSON"
  exit "${PIP_AUDIT_EXIT_CODE:-0}"
fi
printf 'pip-audit %s\n' "$*" >>"$RUN_LOG"
EOF

cat >"$stub_dir/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${RUN_MODE:-text}" = "json" ] && [ "${PODMAN_FAIL_SILENTLY:-0}" = "1" ]; then
  exit "${PODMAN_EXIT_CODE:-1}"
fi
printf 'podman %s\n' "$*" >>"$RUN_LOG"
EOF

chmod +x "$stub_dir/trivy" "$stub_dir/pip-audit" "$stub_dir/podman"
chmod +x "$missing_python_dir/python3"
ln -s "$stub_dir/pip-audit" "$missing_rg_dir/pip-audit"
ln -s "$stub_dir/trivy" "$missing_python_dir/trivy"
ln -s "$stub_dir/podman" "$missing_python_dir/podman"
ln -s "$stub_dir/trivy" "$partial_scan_dir/trivy"
ln -s "$stub_dir/podman" "$partial_scan_dir/podman"

python_repo="$tmp_root/python-repo"
mkdir -p "$python_repo"
python_repo="$(cd "$python_repo" && pwd)"
printf 'flask==3.0.0\n' >"$python_repo/requirements.txt"
cat >"$python_repo/.repo-guard.yaml" <<'EOF'
version: 1
scanning:
  severity: "CRITICAL"
  image_name: "local/custom:dev"
suppressions:
  - id: "PYSEC-2026-42"
    tools: ["pip-audit"]
    package: "flask"
    reason: "accepted in test fixture"
EOF
single_quoted_repo="$tmp_root/single-quoted-repo"
mkdir -p "$single_quoted_repo"
single_quoted_repo="$(cd "$single_quoted_repo" && pwd)"
printf 'flask==3.0.0\n' >"$single_quoted_repo/requirements.txt"
cat >"$single_quoted_repo/.repo-guard.yaml" <<'EOF'
version: 1
scanning:
  severity: 'CRITICAL'
  image_name: 'local/custom:dev'
suppressions:
  - id: 'PYSEC-2026-42'
    tools: ['pip-audit']
    package: 'flask'
    reason: 'accepted in single quoted fixture'
EOF
cat >"$tmp_root/pip-audit.json" <<'EOF'
{
  "dependencies": [
    {
      "name": "flask",
      "version": "3.0.0",
      "vulns": [
        {
          "id": "PYSEC-2026-42",
          "fix_versions": ["3.0.1"],
          "aliases": [],
          "description": "suppressed fixture finding"
        },
        {
          "id": "PYSEC-2026-99",
          "fix_versions": ["3.1.0"],
          "aliases": [],
          "description": "unsuppressed fixture finding"
        }
      ]
    }
  ]
}
EOF
cat >"$tmp_root/pip-audit-suppressed-only.json" <<'EOF'
{
  "dependencies": [
    {
      "name": "flask",
      "version": "3.0.0",
      "vulns": [
        {
          "id": "PYSEC-2026-42",
          "fix_versions": ["3.0.1"],
          "aliases": [],
          "description": "suppressed-only fixture finding"
        }
      ]
    }
  ]
}
EOF
: >"$tmp_root/pip-audit-empty.json"
cat >"$tmp_root/pip-audit-array.json" <<'EOF'
[]
EOF

container_repo="$tmp_root/container-repo"
mkdir -p "$container_repo"
container_repo="$(cd "$container_repo" && pwd)"
printf 'FROM python:3.12-slim\n' >"$container_repo/Dockerfile"
mixed_repo="$tmp_root/mixed-repo"
mkdir -p "$mixed_repo"
mixed_repo="$(cd "$mixed_repo" && pwd)"
printf 'flask==3.0.0\n' >"$mixed_repo/requirements.txt"
printf 'FROM python:3.12-slim\n' >"$mixed_repo/Dockerfile"
configured_container_repo="$tmp_root/configured-container-repo"
mkdir -p "$configured_container_repo"
configured_container_repo="$(cd "$configured_container_repo" && pwd)"
printf 'FROM alpine:3.20\n' >"$configured_container_repo/Dockerfile"
cat >"$configured_container_repo/.repo-guard.yaml" <<'EOF'
version: 1
scanning:
  severity: "CRITICAL"
  image_name: "local/custom:dev"
EOF
cat >"$tmp_root/trivy-empty.json" <<'EOF'
{
  "Results": []
}
EOF
cat >"$tmp_root/trivy-issues.json" <<'EOF'
{
  "Results": [
    {
      "Target": "Dockerfile",
      "Misconfigurations": [
        {
          "ID": "AVD-DS-0001",
          "Severity": "HIGH"
        }
      ]
    }
  ]
}
EOF

control_repo="$tmp_root/control-repo"
mkdir -p "$control_repo"
control_repo="$(cd "$control_repo" && pwd)"
printf 'FROM alpine:3.20\n' >"$control_repo/Dockerfile"

empty_repo="$tmp_root/empty-repo"
mkdir -p "$empty_repo"
empty_repo="$(cd "$empty_repo" && pwd)"

: >"$tmp_root/no-manifest.json"
no_manifest_repo="$tmp_root/no-manifest-repo"
mkdir -p "$no_manifest_repo"
no_manifest_repo="$(cd "$no_manifest_repo" && pwd)"
printf 'print("hello")\n' >"$no_manifest_repo/app.py"
malformed_config_repo="$tmp_root/malformed-config-repo"
mkdir -p "$malformed_config_repo"
malformed_config_repo="$(cd "$malformed_config_repo" && pwd)"
printf 'flask==3.0.0\n' >"$malformed_config_repo/requirements.txt"
cat >"$malformed_config_repo/.repo-guard.yaml" <<'EOF'
version: 1
audit:
  exclude:
      - "archive/**"
EOF

: >"$run_log"
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run "$python_repo" >/dev/null
grep -Fq 'pip-audit -r requirements.txt' "$run_log"
if grep -Fq 'podman ' "$run_log"; then
  echo "python-only run unexpectedly invoked podman" >&2
  exit 1
fi

: >"$run_log"
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run "$container_repo" >/dev/null
grep -Fq "trivy fs --severity HIGH,CRITICAL --exit-code 1 $container_repo" "$run_log"
grep -Fq "trivy config --severity HIGH,CRITICAL --exit-code 1 $container_repo" "$run_log"

: >"$run_log"
if env PATH="$path_value" RUN_LOG="$run_log" \
  TRIVY_FS_EXIT_CODE=1 TRIVY_CONFIG_EXIT_CODE=0 \
  "$script" run "$container_repo" >/dev/null; then
  echo "container run unexpectedly exited 0 when trivy fs failed" >&2
  exit 1
fi

: >"$run_log"
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run --deep "$container_repo" >/dev/null
grep -Fq "podman build -t local/repo-guard:dev -f $container_repo/Dockerfile $container_repo" "$run_log"
grep -Fq 'trivy image --severity HIGH,CRITICAL --exit-code 1 local/repo-guard:dev' "$run_log"

: >"$run_log"
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run "$configured_container_repo" >/dev/null
grep -Fq "trivy fs --severity CRITICAL --exit-code 1 $configured_container_repo" "$run_log"
grep -Fq "trivy config --severity CRITICAL --exit-code 1 $configured_container_repo" "$run_log"

: >"$run_log"
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run --deep "$configured_container_repo" >/dev/null
grep -Fq "podman build -t local/custom:dev -f $configured_container_repo/Dockerfile $configured_container_repo" "$run_log"
grep -Fq 'trivy image --severity CRITICAL --exit-code 1 local/custom:dev' "$run_log"

: >"$run_log"
(
  cd "$control_repo"
  env PATH="$path_value" RUN_LOG="$run_log" \
    "$script" run "$python_repo" >/dev/null
)
grep -Fq 'pip-audit -r requirements.txt' "$run_log"
if grep -Fq 'trivy fs --severity HIGH,CRITICAL --exit-code 1' "$run_log"; then
  echo "positional repo path run unexpectedly scanned the current working directory" >&2
  exit 1
fi

: >"$run_log"
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run "$empty_repo" >/dev/null
if [ -s "$run_log" ]; then
  echo "empty repo run unexpectedly invoked scanner tools" >&2
  exit 1
fi

help_output="$("$script" --help)"
printf '%s\n' "$help_output" | grep -Fq 'repo-guard run [--json] [--deep] [repo-path]'
printf '%s\n' "$help_output" | grep -Fq -- '--json             emit one normalized JSON result object to stdout'

if env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$python_repo" >"$tmp_root/run.json"; then
  echo "run --json unexpectedly exited 0 when unsuppressed findings were present" >&2
  exit 1
fi

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
assert check["new_count"] == 0
assert check["known_count"] == 0
assert check["resolved_count"] == 0
assert check["findings"][0]["suppressed"] is True
PY

env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit-suppressed-only.json" \
  PIP_AUDIT_EXIT_CODE=1 \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$python_repo" >"$tmp_root/run-suppressed-only.json"

python3 - "$tmp_root/run-suppressed-only.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "clean"
check = data["checks"][0]
assert check["status"] == "clean"
assert check["suppressed_count"] == 1
assert check["unsuppressed_count"] == 0
PY

if env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  PIP_AUDIT_EXIT_CODE=2 \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$python_repo" >"$tmp_root/run-failed-check.json"; then
  echo "run --json unexpectedly exited 0 when scanner exited non-zero" >&2
  exit 1
fi

python3 - "$tmp_root/run-failed-check.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
assert data["checks"][0]["status"] == "error"
PY

if env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit-empty.json" \
  PIP_AUDIT_EXIT_CODE=2 \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$python_repo" >"$tmp_root/run-silent-failed-check.json"; then
  echo "run --json unexpectedly exited 0 when scanner failed silently" >&2
  exit 1
fi

python3 - "$tmp_root/run-silent-failed-check.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
check = data["checks"][0]
assert check["id"] == "pip-audit"
assert check["status"] == "error"
assert check["finding_count"] == 0
PY

if env PATH="$path_value" RUN_MODE=json \
  PODMAN_FAIL_SILENTLY=1 \
  PODMAN_EXIT_CODE=1 \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json --deep "$container_repo" >"$tmp_root/run-build-failed.json"; then
  echo "run --json --deep unexpectedly exited 0 when podman build failed" >&2
  exit 1
fi

python3 - "$tmp_root/run-build-failed.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
check = next(item for item in data["checks"] if item["id"] == "podman-build")
assert check["status"] == "error"
PY

env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$no_manifest_repo" >"$tmp_root/no-manifest.json"

python3 - "$tmp_root/no-manifest.json" "$no_manifest_repo" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["repo"]["path"] == sys.argv[2]
assert data["status"] == "skipped"
check = data["checks"][0]
assert check["id"] == "pip-audit"
assert check["status"] == "skipped"
PY

if env PATH="$missing_path_value" \
  "$script" run --json "$python_repo" >"$tmp_root/run-missing-tools.json"; then
  echo "run --json unexpectedly exited 0 when pip-audit was missing" >&2
  exit 1
fi

python3 - "$tmp_root/run-missing-tools.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
assert "pip-audit" in data["missing_tools"]
PY

if env PATH="$partial_scan_path_value" RUN_MODE=json \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$mixed_repo" >"$tmp_root/run-partial-scan.json"; then
  echo "run --json unexpectedly exited 0 when a mixed repo missed pip-audit" >&2
  exit 1
fi

python3 - "$tmp_root/run-partial-scan.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
assert "pip-audit" in data["missing_tools"]
assert any(check["id"] == "trivy-fs" for check in data["checks"])
PY

if env PATH="$partial_scan_path_value" RUN_MODE=json \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-issues.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$mixed_repo" >"$tmp_root/run-partial-scan-with-issues.json"; then
  echo "run --json unexpectedly exited 0 when a mixed repo missed pip-audit and trivy found issues" >&2
  exit 1
fi

python3 - "$tmp_root/run-partial-scan-with-issues.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
assert "pip-audit" in data["missing_tools"]
check = next(item for item in data["checks"] if item["id"] == "trivy-config")
assert check["status"] == "issues"
PY

if env PATH="$missing_rg_path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  "$script" run --json "$python_repo" \
  >"$tmp_root/run-missing-rg.stdout" 2>"$tmp_root/run-missing-rg.stderr"; then
  echo "run --json unexpectedly exited 0 when rg was missing" >&2
  exit 1
fi
grep -Fq 'rg is required to detect repo languages for repo-guard run' "$tmp_root/run-missing-rg.stderr"

if env PATH="$missing_python_path_value" RUN_LOG="$run_log" \
  "$script" run "$container_repo" \
  >"$tmp_root/run-missing-python.stdout" 2>"$tmp_root/run-missing-python.stderr"; then
  echo "run unexpectedly exited 0 when python3 was missing" >&2
  exit 1
fi
grep -Fq 'python3 is required for repo-guard run' "$tmp_root/run-missing-python.stderr"

if env PATH="$path_value" \
  "$script" run --json "$malformed_config_repo" \
  >"$tmp_root/malformed-config.stdout" 2>"$tmp_root/malformed-config.stderr"; then
  echo "run --json unexpectedly exited 0 for malformed config" >&2
  exit 1
fi

if grep -Fq 'Traceback (most recent call last):' "$tmp_root/malformed-config.stderr"; then
  echo "malformed config unexpectedly emitted a Python traceback" >&2
  exit 1
fi
grep -Fq 'unsupported indentation' "$tmp_root/malformed-config.stderr"

if env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$single_quoted_repo" >"$tmp_root/run-single-quoted.json"; then
  echo "run --json unexpectedly exited 0 when unsuppressed findings were present in the single-quoted fixture" >&2
  exit 1
fi

python3 - "$tmp_root/run-single-quoted.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
check = data["checks"][0]
assert check["suppressed_count"] == 1
assert check["unsuppressed_count"] == 1
PY

if env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit-array.json" \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
  "$script" run --json "$python_repo" >"$tmp_root/run-invalid-json-shape.json"; then
  echo "run --json unexpectedly exited 0 for unexpected scanner JSON shape" >&2
  exit 1
fi

python3 - "$tmp_root/run-invalid-json-shape.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["status"] == "error"
warnings = data["checks"][0]["warnings"]
assert any("unexpected JSON shape" in warning for warning in warnings)
PY

cat >"$tmp_root/runtime-supported-config.yaml" <<'EOF'
version: 1
audit:
  exclude:
    - "archive/**"
scanning:
  severity: "CRITICAL"
EOF

python3 "$repo_root/bin/repo_guard_runtime.py" resolve-run-config \
  "$tmp_root/runtime-supported-config.yaml" >"$tmp_root/runtime-supported-config.json"

python3 - "$tmp_root/runtime-supported-config.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["severity"] == "CRITICAL"
PY

cat >"$tmp_root/runtime-invalid-version.yaml" <<'EOF'
version: 2
scanning:
  severity: "CRITICAL"
EOF

if python3 "$repo_root/bin/repo_guard_runtime.py" resolve-run-config \
  "$tmp_root/runtime-invalid-version.yaml" \
  >"$tmp_root/runtime-invalid-version.stdout" 2>"$tmp_root/runtime-invalid-version.stderr"; then
  echo "resolve-run-config unexpectedly accepted an unsupported config version" >&2
  exit 1
fi
grep -Fq 'unsupported config version: 2' "$tmp_root/runtime-invalid-version.stderr"

cat >"$tmp_root/runtime-invalid-shape.yaml" <<'EOF'
version: 1
audit: "oops"
EOF

if python3 "$repo_root/bin/repo_guard_runtime.py" resolve-run-config \
  "$tmp_root/runtime-invalid-shape.yaml" \
  >"$tmp_root/runtime-invalid-shape.stdout" 2>"$tmp_root/runtime-invalid-shape.stderr"; then
  echo "resolve-run-config unexpectedly accepted an invalid audit shape" >&2
  exit 1
fi
grep -Fq 'audit must be a mapping' "$tmp_root/runtime-invalid-shape.stderr"

cat >"$tmp_root/runtime-nested-warning-config.yaml" <<'EOF'
version: 1
scanning:
  severty: "CRITICAL"
EOF

python3 "$repo_root/bin/repo_guard_runtime.py" resolve-run-config \
  "$tmp_root/runtime-nested-warning-config.yaml" >"$tmp_root/runtime-nested-warning-config.json"

python3 - "$tmp_root/runtime-nested-warning-config.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["severity"] == "HIGH,CRITICAL"
assert "unknown scanning key: severty" in data["warnings"]
PY

cat >"$tmp_root/runtime-warning-config.yaml" <<'EOF'
version: 1
unknown:
  nested: "value"
scanning:
  severity: "CRITICAL"
EOF

python3 "$repo_root/bin/repo_guard_runtime.py" resolve-run-config \
  "$tmp_root/runtime-warning-config.yaml" >"$tmp_root/runtime-warning-config.json"

python3 - "$tmp_root/runtime-warning-config.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["severity"] == "CRITICAL"
assert "unknown top-level config key: unknown" in data["warnings"]
PY

echo "run test passed"
