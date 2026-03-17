#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/repo-guard"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-test.XXXXXX")"
target_repo="$tmp_root/example-repo"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

"$script" --help >/dev/null
"$script" --dry-run --langs python,typescript "$target_repo" >/dev/null
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null
"$script" --check-tools --langs python >/tmp/repo-guard-check-tools.out 2>/tmp/repo-guard-check-tools.err || true

perl -0pi -e 's/name: ruff check/name: stale ruff check/' "$target_repo/.pre-commit-config.yaml"
"$script" --langs python,typescript --no-install --upgrade "$target_repo" >/dev/null

git_target_repo="$tmp_root/git-repo"
"$script" --langs python --no-install --git-init "$git_target_repo" >/dev/null

test -f "$target_repo/AGENTS.md"
test -f "$target_repo/LOCAL_TOOLING.md"
test -f "$target_repo/.ignore"
test -f "$target_repo/.rgignore"
test -f "$target_repo/.gitignore"
test -f "$target_repo/.pre-commit-config.yaml"

grep -Fqx "# Security Lockdown Rules" "$target_repo/AGENTS.md"
grep -Fqx "# Local Tooling" "$target_repo/LOCAL_TOOLING.md"
grep -Fqx "# repo-guard:base:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:python:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:typescript:start" "$target_repo/.pre-commit-config.yaml"
grep -Fq "id: risky-filenames" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "*env*" "$target_repo/.ignore"
grep -Fqx "*env*" "$target_repo/.rgignore"
grep -Fqx "*env*" "$target_repo/.gitignore"
grep -Fq "|*env*|" "$target_repo/.pre-commit-config.yaml"
grep -Fq "\$VIRTUAL_ENV/bin/ruff" "$target_repo/.pre-commit-config.yaml"
grep -Fq "./.venv/bin/ruff" "$target_repo/.pre-commit-config.yaml"
grep -Fq "./node_modules/.bin/eslint" "$target_repo/.pre-commit-config.yaml"
grep -Fq "./node_modules/.bin/tsc --noEmit" "$target_repo/.pre-commit-config.yaml"
grep -Fq "name: ruff check" "$target_repo/.pre-commit-config.yaml"
if grep -Fq "name: stale ruff check" "$target_repo/.pre-commit-config.yaml"; then
  echo "upgrade did not refresh managed python block" >&2
  exit 1
fi
grep -Fq "tool versions:" /tmp/repo-guard-check-tools.out
grep -Fq "minimum tested" /tmp/repo-guard-check-tools.out

base_count="$(grep -Fc "# repo-guard:base:start" "$target_repo/.pre-commit-config.yaml")"
python_count="$(grep -Fc "# repo-guard:python:start" "$target_repo/.pre-commit-config.yaml")"
typescript_count="$(grep -Fc "# repo-guard:typescript:start" "$target_repo/.pre-commit-config.yaml")"

test "$base_count" -eq 1
test "$python_count" -eq 1
test "$typescript_count" -eq 1
test -d "$git_target_repo/.git"
test -f "$git_target_repo/.git/hooks/pre-commit"

echo "smoke test passed"
