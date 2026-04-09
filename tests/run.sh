#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/repo-guard"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-run.XXXXXX")"
stub_dir="$tmp_root/stubs"
run_log="$tmp_root/run.log"
path_value="$stub_dir:$PATH"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$stub_dir"

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
printf 'podman %s\n' "$*" >>"$RUN_LOG"
EOF

chmod +x "$stub_dir/trivy" "$stub_dir/pip-audit" "$stub_dir/podman"

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

container_repo="$tmp_root/container-repo"
mkdir -p "$container_repo"
container_repo="$(cd "$container_repo" && pwd)"
printf 'FROM python:3.12-slim\n' >"$container_repo/Dockerfile"
cat >"$tmp_root/trivy-empty.json" <<'EOF'
{
  "Results": []
}
EOF

control_repo="$tmp_root/control-repo"
mkdir -p "$control_repo"
control_repo="$(cd "$control_repo" && pwd)"
printf 'FROM alpine:3.20\n' >"$control_repo/Dockerfile"

empty_repo="$tmp_root/empty-repo"
mkdir -p "$empty_repo"
empty_repo="$(cd "$empty_repo" && pwd)"

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
env PATH="$path_value" RUN_LOG="$run_log" \
  "$script" run --deep "$container_repo" >/dev/null
grep -Fq "podman build -t local/repo-guard:dev -f $container_repo/Dockerfile $container_repo" "$run_log"
grep -Fq 'trivy image --severity HIGH,CRITICAL --exit-code 1 local/repo-guard:dev' "$run_log"

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

env PATH="$path_value" RUN_MODE=json \
  PIP_AUDIT_JSON="$tmp_root/pip-audit.json" \
  TRIVY_FS_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_CONFIG_JSON="$tmp_root/trivy-empty.json" \
  TRIVY_IMAGE_JSON="$tmp_root/trivy-empty.json" \
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

echo "run test passed"
