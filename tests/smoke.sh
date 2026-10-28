#!/usr/bin/env bash

set -Eeuo pipefail

# CI logs are not always reachable, but annotations are: report the failing line.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  trap 'echo "::error file=tests/smoke.sh,line=$LINENO::failed: $BASH_COMMAND"' ERR
fi

fail() {
  echo "$*" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error file=tests/smoke.sh::$*"
  fi
  exit 1
}

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
  fail "upgrade did not refresh managed python block"
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
      fail "risky-filenames allowed nested secret path: $f"
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
  fail "pre-commit template contains lines longer than 100 characters"
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
  fail "generated .pre-commit-config.yaml contains lines longer than 100 characters"
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
  fail "upgrade did not remove legacy base block with changed hook entry"
fi
if grep -Fq '# repo-guard:python:start' "$upgrade_legacy_repo/.pre-commit-config.yaml"; then
  fail "upgrade should not have added python block when no langs selected"
fi

echo "smoke test passed"

# Custom gitleaks rules catch the low-entropy config secrets the default rules miss.
if ! command -v gitleaks >/dev/null 2>&1 && [ -n "${CI:-}" ]; then
  fail "gitleaks is required in CI; the secret-detection tests would be skipped"
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
      fail "gitleaks missed: $line"
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
  fail "--upgrade left managed content outdated"
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
    fail "bootstrap passed a repo with a secret in its history"
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
  fail "--upgrade passed while keeping a block with custom hooks"
fi
grep -Fq "id: my-custom-hook" "$custom_repo/.pre-commit-config.yaml"
grep -Fq "hooks the template lacks (my-custom-hook)" "$tmp_root/custom.err"

# Optional tools are skipped locally when missing but mandatory under CI.
have_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${CI:-}" ]; then
    fail "$1 is required in CI; its tests would be skipped"
  fi
  return 1
}

# Large files and model weights are refused; Git LFS files are not.
lf_repo="$tmp_root/large-files-repo"
"$script" --no-install "$lf_repo" >/dev/null
(
  cd "$lf_repo"
  git init -q
  printf 'small\n' >small.txt
  head -c 6000000 /dev/zero >big.bin
  : >model.gguf
  head -c 6000000 /dev/zero >tracked-by-lfs.bin
  printf 'tracked-by-lfs.bin filter=lfs diff=lfs merge=lfs -text\n' >.gitattributes
  pre-commit run large-files --files small.txt tracked-by-lfs.bin >/dev/null
  for f in big.bin model.gguf; do
    if pre-commit run large-files --files "$f" >/dev/null; then
      fail "large-files allowed $f"
    fi
  done
  REPO_GUARD_MAX_FILE_KB=10000 pre-commit run large-files --files big.bin >/dev/null
)

# A GitHub origin implies the actions checks; JS/TS implies osv.
grep -Fqx "# repo-guard:actions:start" "$gh_repo/.pre-commit-config.yaml"
if grep -Fqx "# repo-guard:actions:start" "$other_repo/.pre-commit-config.yaml"; then
  fail "actions checks added without a GitHub origin"
fi
js_repo="$tmp_root/js-repo"
"$script" --no-install --langs javascript "$js_repo" >/dev/null
grep -Fqx "# repo-guard:osv:start" "$js_repo/.pre-commit-config.yaml"

# The workflows repo-guard ships and runs must pass its own actions checks.
if have_tool actionlint && have_tool zizmor; then
  for wf in "$repo_root/templates/repo-guard/github-workflow.yml" "$repo_root"/.github/workflows/*.yml; do
    actionlint "$wf"
    zizmor --offline --no-progress "$wf" >/dev/null
  done
  bad_wf_repo="$tmp_root/bad-workflow-repo"
  "$script" --no-install --langs actions "$bad_wf_repo" >/dev/null
  (
    cd "$bad_wf_repo"
    git init -q
    mkdir -p .github/workflows
    # shellcheck disable=SC2016 # the unexpanded expression is the injection under test
    printf '%s\n' 'on: pull_request_target' 'permissions: {}' 'jobs:' '  t:' \
      '    runs-on: ubuntu-latest' '    steps:' \
      '      - run: echo "${{ github.event.pull_request.title }}"' >.github/workflows/bad.yml
    if pre-commit run zizmor --files .github/workflows/bad.yml >/dev/null; then
      fail "zizmor passed a template-injection workflow"
    fi
  )
fi

if have_tool semgrep; then
  sast_repo="$tmp_root/sast-repo"
  "$script" --no-install --langs semgrep "$sast_repo" >/dev/null
  (
    cd "$sast_repo"
    git init -q
    printf 'import subprocess, sys\nsubprocess.call(sys.argv[1], shell=True)\n' >bad.py
    printf 'print("ok")\n' >ok.py
    pre-commit run semgrep --files ok.py >/dev/null
    if pre-commit run semgrep --files bad.py >/dev/null; then
      fail "semgrep passed shell=True with user input"
    fi
  )
fi

# osv.dev is unreachable from some networks, so this only runs in CI.
if [ -n "${CI:-}" ] && have_tool osv-scanner; then
  osv_repo="$tmp_root/osv-repo"
  "$script" --no-install --langs osv "$osv_repo" >/dev/null
  (
    cd "$osv_repo"
    git init -q
    printf '%s\n' '{"name":"t","version":"1.0.0","lockfileVersion":3,"requires":true,' \
      '"packages":{"":{"name":"t","version":"1.0.0","dependencies":{"lodash":"4.17.15"}},' \
      '"node_modules/lodash":{"version":"4.17.15",' \
      '"resolved":"https://registry.npmjs.org/lodash/-/lodash-4.17.15.tgz",' \
      '"integrity":"sha512-8xOcRHvCjnocdS5cpwXQXVzmmh5e5+saE2QGoeQmbKmRS6J3VQppPOIt0MnmE+4xlZoumy0GPG0D0MVIQbNA1A=="}}}' \
      >package-lock.json
    if pre-commit run osv-scanner --files package-lock.json >/dev/null; then
      fail "osv-scanner passed lodash 4.17.15"
    fi
  )
fi

# repo-guard remote: a stub gh answers from one file per API path.
gh_stub="$tmp_root/gh-stub"
mkdir -p "$gh_stub/bin"
cat >"$gh_stub/bin/gh" <<'STUB'
#!/usr/bin/env bash
path=$2
case "$path" in
  repos/example/repo) key=repo ;;
  */vulnerability-alerts) key=alerts ;;
  */contents/.github/workflows/repo-guard.yml*) key=workflow ;;
  */actions/workflows/repo-guard.yml/runs*) key=runs ;;
  */rules/branches/*) key=rules ;;
  *) key=none ;;
esac
f="$GH_STUB_DIR/$key"
if [ ! -f "$f" ]; then
  fail "gh: Not Found (HTTP 404)"
fi
cat "$f"
STUB
chmod +x "$gh_stub/bin/gh"
remote_repo="$tmp_root/remote-repo"
mkdir -p "$remote_repo"
git -C "$remote_repo" init -q
git -C "$remote_repo" remote add origin git@github.com:example/repo.git
good="$gh_stub/good"
mkdir -p "$good"
printf 'main\tpublic\tenabled\tenabled\n' >"$good/repo"
: >"$good/alerts"
: >"$good/workflow"
printf 'success\n' >"$good/runs"
printf 'true\n' >"$good/rules"
PATH="$gh_stub/bin:$PATH" GH_STUB_DIR="$good" "$script" remote "$remote_repo" >"$tmp_root/remote-good.out" 2>&1
if grep -Eq "FAIL|warn" "$tmp_root/remote-good.out"; then
  fail "remote flagged a fully configured repo"
fi
bad="$gh_stub/bad"
mkdir -p "$bad"
printf 'main\tpublic\tenabled\tdisabled\n' >"$bad/repo"
if PATH="$gh_stub/bin:$PATH" GH_STUB_DIR="$bad" "$script" remote "$remote_repo" >"$tmp_root/remote-bad.out" 2>&1; then
  fail "remote passed a repo without push protection, alerts or workflow"
fi
grep -Fq "FAIL  secret scanning push protection" "$tmp_root/remote-bad.out"
grep -Fq "secret_scanning_push_protection][status]=enabled" "$tmp_root/remote-bad.out"
grep -Fq "FAIL  Dependabot alerts are disabled" "$tmp_root/remote-bad.out"
grep -Fq "FAIL  no .github/workflows/repo-guard.yml on main" "$tmp_root/remote-bad.out"
grep -Fq "warn  repo-guard 'secrets' check is not required" "$tmp_root/remote-bad.out"
