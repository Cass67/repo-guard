#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/repo-guard"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-install.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

stub_dir="$tmp_root/stubs"
mkdir -p "$stub_dir"

cat >"$stub_dir/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'brew %s\n' "$*" >>"$REPO_GUARD_INSTALL_LOG"
EOF

cat >"$stub_dir/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'python3 %s\n' "$*" >>"$REPO_GUARD_INSTALL_LOG"
EOF

cat >"$stub_dir/pipx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pipx %s\n' "$*" >>"$REPO_GUARD_INSTALL_LOG"
EOF

chmod +x "$stub_dir/brew" "$stub_dir/python3" "$stub_dir/pipx"

run_case() {
  local case_name=$1
  local langs_csv=$2
  local virtual_env=${3:-}
  local use_pipx=${4:-no}
  local repo="$tmp_root/$case_name-repo"
  local log_file="$tmp_root/$case_name.log"
  local path_value="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin"

  mkdir -p "$repo"
  : >"$log_file"

  if [ "$use_pipx" != "yes" ]; then
    path_value="$tmp_root/no-pipx:/usr/bin:/bin:/usr/sbin:/sbin"
    mkdir -p "$tmp_root/no-pipx"
    ln -sf "$stub_dir/brew" "$tmp_root/no-pipx/brew"
    ln -sf "$stub_dir/python3" "$tmp_root/no-pipx/python3"
  fi

  if [ -n "$virtual_env" ]; then
    env \
      PATH="$path_value" \
      REPO_GUARD_INSTALL_LOG="$log_file" \
      VIRTUAL_ENV="$virtual_env" \
      "$script" --langs "$langs_csv" --yes "$repo" >/dev/null
  else
    env \
      -u VIRTUAL_ENV \
      PATH="$path_value" \
      REPO_GUARD_INSTALL_LOG="$log_file" \
      "$script" --langs "$langs_csv" --yes "$repo" >/dev/null
  fi

  printf '%s\n' "$log_file"
}

venv_log="$(run_case venv ansible "$tmp_root/fake-venv")"
grep -Fq 'python3 -m pip install ansible-lint' "$venv_log"
grep -Fq 'python3 -m pip install djlint' "$venv_log"
if grep -Fq -- '--user' "$venv_log"; then
  echo "virtualenv install unexpectedly used --user" >&2
  exit 1
fi

venv_pipx_log="$(run_case venv-pipx ansible "$tmp_root/fake-venv" yes)"
grep -Fq 'python3 -m pip install ansible-lint' "$venv_pipx_log"
grep -Fq 'python3 -m pip install djlint' "$venv_pipx_log"
if grep -Fq 'pipx install' "$venv_pipx_log"; then
  echo "virtualenv install unexpectedly used pipx" >&2
  exit 1
fi

plain_log="$(run_case plain ansible)"
grep -Fq 'python3 -m pip install --user ansible-lint' "$plain_log"
grep -Fq 'python3 -m pip install --user djlint' "$plain_log"
grep -Fq 'brew install yamllint' "$plain_log"

python_plain_log="$(run_case python-plain python)"
grep -Fq 'python3 -m pip install --user pip-audit' "$python_plain_log"

python_venv_log="$(run_case python-venv python "$tmp_root/fake-venv")"
grep -Fq 'python3 -m pip install pip-audit' "$python_venv_log"
if grep -Fq -- '--user' "$python_venv_log"; then
  echo "python virtualenv install unexpectedly used --user" >&2
  exit 1
fi

echo "install python cli test passed"
