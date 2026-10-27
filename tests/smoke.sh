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

# GNU stat (Linux) and BSD stat (macOS) spell the mode format differently.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

git_commit() {
  git -c user.name=repo-guard-test -c user.email=test@example.invalid commit -q "$@"
}

"$script" --help >/dev/null
"$script" --dry-run --langs python,typescript "$target_repo" >/dev/null
container_repo="$tmp_root/container-repo"
mkdir -p "$container_repo"
printf 'FROM python:3.12-slim\n' >"$container_repo/Dockerfile"
"$script" --langs containers --no-install "$container_repo" >/dev/null
mkdir -p "$target_repo"
printf 'Legacy repo agent note\n' >"$target_repo/AGENTS.md"
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null
"$script" --check-tools --langs python >/tmp/repo-guard-check-tools.out 2>/tmp/repo-guard-check-tools.err || true
"$script" --check-tools --langs containers >/tmp/repo-guard-check-tools-containers.out 2>/tmp/repo-guard-check-tools-containers.err || true
printf '\n// keep me\n' >>"$target_repo/renovate.json"
"$script" --langs python,typescript --no-install "$target_repo" >/dev/null

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
test -f "$target_repo/renovate.json"
test -f "$target_repo/.gitleaks.toml"
test -f "$container_repo/.pre-commit-config.yaml"

grep -Fqx "# Security Lockdown Rules" "$target_repo/AGENTS.md"
grep -Fqx "Legacy repo agent note" "$target_repo/AGENTS_renamed.md"
grep -Fq "Previous repo-level instructions were preserved at \`AGENTS_renamed.md\`." "$target_repo/AGENTS.md"
grep -Fqx "# Local Tooling" "$target_repo/LOCAL_TOOLING.md"
grep -Fq '"config:recommended"' "$target_repo/renovate.json"
grep -Fqx "## Containers / Supply Chain" "$target_repo/LOCAL_TOOLING.md"
grep -Fqx "# repo-guard:base:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:python:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:typescript:start" "$target_repo/.pre-commit-config.yaml"
grep -Fqx "# repo-guard:containers:start" "$container_repo/.pre-commit-config.yaml"
grep -Fq "id: risky-filenames" "$target_repo/.pre-commit-config.yaml"
grep -Fq "id: pip-audit" "$target_repo/.pre-commit-config.yaml"
grep -Fq "id: trivy-fs" "$container_repo/.pre-commit-config.yaml"
grep -Fqx -- "- \`trivy\`" "$target_repo/LOCAL_TOOLING.md"
grep -Fqx -- "- \`pip-audit\`" "$target_repo/LOCAL_TOOLING.md"
grep -Fqx "*env*" "$target_repo/.ignore"
grep -Fqx "*env*" "$target_repo/.rgignore"
grep -Fqx "*env*" "$target_repo/.gitignore"
grep -Fqx "/.repo-guard/reports/" "$target_repo/.gitignore"
grep -Fqx "/.repo-guard/reports/" "$target_repo/.ignore"
grep -Fqx "/.repo-guard/reports/" "$target_repo/.rgignore"
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
grep -Fq "trivy" /tmp/repo-guard-check-tools-containers.out
grep -Fq "// keep me" "$target_repo/renovate.json"

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
  mkdir -p deploy infra/.ssh k8s services/api
  for f in deploy/id_rsa infra/.ssh/id_ed25519 k8s/secrets.yaml services/api/.env; do
    : >"$f"
    if pre-commit run risky-filenames --files "$f" >/dev/null; then
      echo "risky-filenames allowed nested secret path: $f" >&2
      exit 1
    fi
  done
  : >services/api/.env.example
  pre-commit run risky-filenames --files services/api/.env.example >/dev/null
  # eslint must skip (exit 0) when the repo has no ESLint config
  printf 'export const x = 1;\n' >skip-lint.ts
  pre-commit run eslint --files skip-lint.ts >/dev/null
)

if python3 - "$repo_root" <<'PY'
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
then
  :
else
  echo "pre-commit template contains lines longer than 100 characters" >&2
  exit 1
fi

if python3 - "$target_repo/.pre-commit-config.yaml" <<'PY'
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
then
  :
else
  echo "generated .pre-commit-config.yaml contains lines longer than 100 characters" >&2
  exit 1
fi

# Permissions: secret-bearing files get 600; non-secret files get 644.
test "$(file_mode "$target_repo/AGENTS.md")" = '600'
test "$(file_mode "$target_repo/renovate.json")" = '600'
test "$(file_mode "$target_repo/.gitignore")" = '644'
test "$(file_mode "$target_repo/.gitleaks.toml")" = '644'
test "$(file_mode "$target_repo/.ignore")" = '644'
test "$(file_mode "$target_repo/.rgignore")" = '644'
test "$(file_mode "$target_repo/.pre-commit-config.yaml")" = '644'
test "$(file_mode "$target_repo/LOCAL_TOOLING.md")" = '644'

# Upgrade preserves managed markers, drops legacy block even with changed hook entry.
upgrade_legacy_repo="$tmp_root/upgrade-legacy-repo"
mkdir -p "$upgrade_legacy_repo"
cat >"$upgrade_legacy_repo/.pre-commit-config.yaml" <<'EOF'
repos:
  # repo-guard:base:start
  - repo: local
    hooks:
      - id: risky-filenames
        name: risky filenames
        entry: bash -lc 'status=0; for f in "$@"; do case "$f" in .env|.env.*|*.env) printf "refusing %s\n" "$f"; status=1 ;; esac; done; exit "$status"' --
        language: system
  # repo-guard:base:end
EOF
"$script" --no-install --upgrade "$upgrade_legacy_repo" >/dev/null
grep -Fq "# repo-guard:base:start" "$upgrade_legacy_repo/.pre-commit-config.yaml"
if grep -Fq 'refusing %s' "$upgrade_legacy_repo/.pre-commit-config.yaml"; then
  echo "upgrade did not remove legacy base block with changed hook entry" >&2
  exit 1
fi
if grep -Fq '# repo-guard:python:start' "$upgrade_legacy_repo/.pre-commit-config.yaml"; then
  echo "upgrade should not have added python block when no langs selected" >&2
  exit 1
fi

echo "smoke test passed"

# Custom gitleaks rules catch the low-entropy config secrets the default rules miss.
if ! command -v gitleaks >/dev/null 2>&1 && [ -n "${CI:-}" ]; then
  echo "gitleaks is required in CI; the secret-detection tests would be skipped" >&2
  exit 1
fi
if command -v gitleaks >/dev/null 2>&1; then
  leak_dir="$tmp_root/leak"
  mkdir -p "$leak_dir"
  cp "$target_repo/.gitleaks.toml" "$leak_dir/"
  # Fixtures, not secrets: gitleaks:allow keeps this repo's own scan clean.
  # shellcheck disable=SC2016 # literal ${...} is the test input
  leak_lines=(
    'POSTGRES_PASSWORD: hunter22'                                       # gitleaks:allow
    'GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD:-hunter22}"' # gitleaks:allow
    'DATABASE_URL: "postgresql://app:hunter22@db:5432/app"'             # gitleaks:allow
  )
  for line in "${leak_lines[@]}"; do
    printf 'services:\n  db:\n    environment:\n      %s\n' "$line" >"$leak_dir/compose.yml"
    if gitleaks dir --no-banner -c "$leak_dir/.gitleaks.toml" "$leak_dir" >/dev/null 2>&1; then
      echo "gitleaks missed: $line" >&2
      exit 1
    fi
  done
  # shellcheck disable=SC2016
  printf 'services:\n  db:\n    environment:\n      %s\n      %s\n' \
    'POSTGRES_PASSWORD: "${DB_PASSWORD:?set in .env}"' \
    'DATABASE_URL: "postgresql://app:${DB_PASSWORD}@db:5432/app"' >"$leak_dir/compose.yml"
  gitleaks dir --no-banner -c "$leak_dir/.gitleaks.toml" "$leak_dir" >/dev/null 2>&1
fi

# Stale managed blocks and files are reported, and --upgrade refreshes them.
stale_repo="$tmp_root/stale-repo"
"$script" --no-install "$stale_repo" >/dev/null
sed -i.orig 's/name: merge conflict markers/name: edited by hand/' "$stale_repo/.pre-commit-config.yaml"
printf '# local edit\n' >>"$stale_repo/.gitleaks.toml"
"$script" --no-install "$stale_repo" 2>"$tmp_root/stale.err" >/dev/null
grep -Eq "repo-guard:base:start in .*/stale-repo/.pre-commit-config.yaml is outdated" "$tmp_root/stale.err"
grep -Eq "/stale-repo/.gitleaks.toml is outdated" "$tmp_root/stale.err"
"$script" --no-install --upgrade "$stale_repo" 2>"$tmp_root/stale.err" >/dev/null
if grep -Fq "outdated" "$tmp_root/stale.err"; then
  echo "--upgrade left managed content outdated" >&2
  exit 1
fi
cmp -s "$repo_root/templates/repo-guard/.gitleaks.toml" "$stale_repo/.gitleaks.toml"
grep -Fv "# repo-guard:managed" "$stale_repo/.gitleaks.toml" >"$tmp_root/unmanaged.toml"
printf '# kept\n' >>"$tmp_root/unmanaged.toml"
cp "$tmp_root/unmanaged.toml" "$stale_repo/.gitleaks.toml"
"$script" --no-install --upgrade "$stale_repo" >/dev/null
grep -Fqx "# kept" "$stale_repo/.gitleaks.toml"

# GitHub remotes get the server-side workflow; other remotes do not.
gh_repo="$tmp_root/gh-repo"
other_repo="$tmp_root/other-repo"
for r in "$gh_repo" "$other_repo"; do
  mkdir -p "$r"
  git -C "$r" init -q
done
git -C "$gh_repo" remote add origin git@github.com:example/repo.git
git -C "$other_repo" remote add origin https://gitlab.example.invalid/example/repo.git
"$script" --no-install "$gh_repo" >/dev/null
"$script" --no-install "$other_repo" >/dev/null
grep -Fq "ghcr.io/gitleaks/gitleaks:" "$gh_repo/.github/workflows/repo-guard.yml"
test ! -e "$other_repo/.github/workflows/repo-guard.yml"

# Secrets already in history fail the bootstrap instead of passing silently.
if command -v gitleaks >/dev/null 2>&1; then
  leaky_repo="$tmp_root/leaky-repo"
  mkdir -p "$leaky_repo"
  (
    cd "$leaky_repo"
    git init -q
    printf 'services:\n  db:\n    environment:\n      POSTGRES_PASSWORD: hunter22\n' >compose.yml # gitleaks:allow
    git add compose.yml
    git_commit -m "leak"
  )
  if "$script" --no-install "$leaky_repo" >/dev/null 2>"$tmp_root/leaky.err"; then
    echo "bootstrap passed a repo with a secret in its history" >&2
    exit 1
  fi
  grep -Fq "secret(s) in existing git history" "$tmp_root/leaky.err"
fi

# --upgrade never deletes hooks someone added inside a managed block.
custom_repo="$tmp_root/custom-repo"
"$script" --no-install --langs bash "$custom_repo" >/dev/null
awk '{ print } $0 == "# repo-guard:bash:start" { getline; print; getline; print
  print "      - id: my-custom-hook"
  print "        name: my custom hook"
  print "        entry: \"true\""
  print "        language: system" }' "$custom_repo/.pre-commit-config.yaml" >"$tmp_root/custom.yaml"
mv "$tmp_root/custom.yaml" "$custom_repo/.pre-commit-config.yaml"
if "$script" --no-install --upgrade "$custom_repo" >/dev/null 2>"$tmp_root/custom.err"; then
  echo "--upgrade passed while keeping a block with custom hooks" >&2
  exit 1
fi
grep -Fq "id: my-custom-hook" "$custom_repo/.pre-commit-config.yaml"
grep -Fq "hooks the template lacks (my-custom-hook)" "$tmp_root/custom.err"
