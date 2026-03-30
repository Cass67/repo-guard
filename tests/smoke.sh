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
mkdir -p "$target_repo"
printf 'Legacy repo agent note\n' >"$target_repo/AGENTS.md"
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null
"$script" --check-tools --langs python >/tmp/repo-guard-check-tools.out 2>/tmp/repo-guard-check-tools.err || true

tmp_legacy="$tmp_root/legacy-prettier-block.txt"
cat >"$tmp_legacy" <<'EOF'
  - repo: local
    hooks:
      - id: eslint
        name: eslint
        entry: bash -lc 'if [ -x ./node_modules/.bin/eslint ]; then ./node_modules/.bin/eslint "$@"; else eslint "$@"; fi' --
        language: system
        files: \.(ts|tsx|mts|cts)$
      - id: prettier
        name: prettier
        entry: bash -lc 'if [ -x ./node_modules/.bin/prettier ]; then ./node_modules/.bin/prettier --write "$@"; else prettier --write "$@"; fi' --
        language: system
        files: \.(ts|tsx|mts|cts|json|md|yaml|yml)$
EOF
python3 - "$target_repo/.pre-commit-config.yaml" "$tmp_legacy" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
legacy = Path(sys.argv[2]).read_text()
target.write_text("repos:\n\n" + legacy + "\n" + target.read_text().removeprefix("repos:\n"))
PY

perl -0pi -e 's/name: ruff check/name: stale ruff check/' "$target_repo/.pre-commit-config.yaml"
"$script" --no-install --upgrade "$target_repo" >/dev/null

git_target_repo="$tmp_root/git-repo"
"$script" --langs python --no-install --git-init "$git_target_repo" >/dev/null

test -f "$target_repo/AGENTS.md"
test -f "$target_repo/AGENTS_renamed.md"
test -f "$target_repo/LOCAL_TOOLING.md"
test -f "$target_repo/.ignore"
test -f "$target_repo/.rgignore"
test -f "$target_repo/.gitignore"
test -f "$target_repo/.pre-commit-config.yaml"

grep -Fqx "# Security Lockdown Rules" "$target_repo/AGENTS.md"
grep -Fqx "Legacy repo agent note" "$target_repo/AGENTS_renamed.md"
grep -Fq "Previous repo-level instructions were preserved at \`AGENTS_renamed.md\`." "$target_repo/AGENTS.md"
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
grep -Fq "exclude: ^\\.pre-commit-config\\.yaml$" "$target_repo/.pre-commit-config.yaml"
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
test "$(grep -Fc "id: prettier" "$target_repo/.pre-commit-config.yaml")" -eq 1
test -d "$git_target_repo/.git"
test -f "$git_target_repo/.git/hooks/pre-commit"
(
  cd "$target_repo"
  git init -q
  printf 'safe\n' >safe.txt
  pre-commit run risky-filenames --files safe.txt >/dev/null
)

if python3 - "$repo_root" <<'PY'; then
from pathlib import Path
import sys

root = Path(sys.argv[1])
violations = []
for path in sorted((root / "templates" / "repo-guard" / "pre-commit").glob("*.yaml")):
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        if len(line) > 100:
            violations.append(f"{path}:{lineno}:{len(line)}")

if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
  :
else
  echo "pre-commit template contains lines longer than 100 characters" >&2
  exit 1
fi

if python3 - "$target_repo/.pre-commit-config.yaml" <<'PY'; then
from pathlib import Path
import sys

path = Path(sys.argv[1])
violations = []
for lineno, line in enumerate(path.read_text().splitlines(), start=1):
    if len(line) > 100:
        violations.append(f"{path}:{lineno}:{len(line)}")

if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
  :
else
  echo "generated .pre-commit-config.yaml contains lines longer than 100 characters" >&2
  exit 1
fi

echo "smoke test passed"
