#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/repo-guard"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-detect.XXXXXX")"
target_repo="$tmp_root/existing-repo"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$target_repo/src" "$target_repo/web" "$target_repo/roles/example/tasks" "$target_repo/templates"
printf 'print("ok")\n' >"$target_repo/src/app.py"
printf 'console.log("ok")\n' >"$target_repo/web/app.js"
printf 'export const value: number = 1;\n' >"$target_repo/web/app.ts"
printf -- '- hosts: all\n  tasks:\n    - debug:\n        msg: ok\n' >"$target_repo/roles/example/tasks/main.yml"
printf '{{ value }}\n' >"$target_repo/templates/config.j2"
printf 'node_modules/\n' >"$target_repo/.gitignore"
mkdir -p "$target_repo/node_modules"
printf 'ignored\n' >"$target_repo/node_modules/ignored.ts"

"$script" --detect --no-install "$target_repo" >/tmp/repo-guard-detect.out

grep -Fq "detected repo languages: python, javascript, typescript, ansible" /tmp/repo-guard-detect.out
grep -Fqx "# repo-guard:python:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:javascript:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:typescript:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:ansible:start" "$target_repo/.pre-commit-config.yaml"

if grep -Fqx "# repo-guard:bash:start" "$target_repo/.pre-commit-config.yaml"; then
  echo "unexpected bash detection" >&2
  exit 1
fi

tmp_container="$tmp_root/container-repo"
mkdir -p "$tmp_container"
printf 'FROM python:3.12-slim\n' >"$tmp_container/Dockerfile"

"$script" --detect --no-install "$tmp_container" >/tmp/repo-guard-detect-container.out
grep -Fq "detected repo languages: containers" /tmp/repo-guard-detect-container.out
grep -Fqx "# repo-guard:containers:start" "$tmp_container/.pre-commit-config.yaml"

echo "detect test passed"
