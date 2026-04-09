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
printf 'trivy %s\n' "$*" >>"$RUN_LOG"
EOF

cat >"$stub_dir/pip-audit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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

container_repo="$tmp_root/container-repo"
mkdir -p "$container_repo"
container_repo="$(cd "$container_repo" && pwd)"
printf 'FROM python:3.12-slim\n' >"$container_repo/Dockerfile"

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

echo "run test passed"
