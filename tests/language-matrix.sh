#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/repo-guard"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-guard-matrix.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

langs=(python go bash rust c javascript typescript ansible containers)

test_repo() {
  local name=$1
  local langs_csv=$2
  local repo="$tmp_root/$name"

  "$script" --langs "$langs_csv" --no-install "$repo" >/dev/null
  test -f "$repo/.pre-commit-config.yaml"
  pre-commit validate-config "$repo/.pre-commit-config.yaml" >/dev/null
}

for lang in "${langs[@]}"; do
  test_repo "$lang" "$lang"
done

test_repo "all-langs" "python,go,bash,rust,c,javascript,typescript,ansible,containers"
test_repo "aliases" "py,js,ts,shell,cpp"

echo "language matrix test passed"
