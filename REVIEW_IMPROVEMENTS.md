# repo-guard Improvement Plan

## Priority 1 — Reliability & Safety

### ShellCheck Compliance
- Run `shellcheck bin/repo-guard` to baseline current findings
- Fix all violations across 1433 lines: unquoted variables in array expansions, `[` vs `[[` usage, unquoted globs, unhandled exit codes
- Add ShellCheck as a CI gate in `.github/workflows/ci.yml`

### Strict Mode Flags
- Upgrade `set -e` → `set -euo pipefail` near top of script (~line 5)
- Audit all command paths where failures are silently swallowed (grep, rg, cp, chmod calls)
- Ensure intentional failures use `|| true` or explicit error handling

## Priority 2 — Feature Gaps

### Version Command & Release
- Define a `VERSION` constant in `bin/repo-guard`
- Implement `--version` flag to print current version
- Add `CHANGELOG.md` to document releases

### --dry-run Verification
- Ensure `--dry-run` produces zero filesystem side effects
- Add test coverage for dry-run behavior in `tests/smoke.sh` or new test file

### Executable Permissions Documentation
- Add note to README that `bin/repo-guard` requires `chmod +x`
- Consider adding a `make install` or one-line bootstrap command

## Priority 3 — Test Coverage

### Edge Case Tests
- **Idempotency**: Run repo-guard 3+ times, assert no duplicate entries
- **AGENTS.md rename**: Test behavior when target already has non-template AGENTS.md
- **Missing templates dir**: Verify graceful failure when templates/ is absent
- **Alias completeness**: Verify all documented aliases resolve correctly
- **Upgrade path**: Test `--upgrade` on pre-existing managed pre-commit blocks

## Priority 4 — Maintainability

### Unified File Listing Strategy
- `detect_languages` uses `rg --files` with two fallback paths (~lines 83-86 and ~1389-1395)
- Consolidate into single reusable helper to prevent drift

### Language Definitions Refactor
- Current: Detection patterns, install commands, and minimum versions are hardcoded across multiple functions
- Consider: Extract to data structure (Bash associative arrays) or external config file (TOML/YAML)
- Benefit: Adding new languages becomes a single addition, not edits across detect/install/check-tools/template selection

## Priority 5 — Housekeeping

### .gitignore Cleanup
- `docs/` is listed in `.gitignore` (line 36) but `docs/` directory exists and is showing as untracked
- Decide: either remove `docs/` from `.gitignore` to track docs/plans content, or confirm it's intentionally ignored

---

## Quick Wins
1. Add `VERSION="0.1.0"` and `--version` flag (~5 lines)
2. Add `chmod +x` note to README installation section
3. Run ShellCheck and fix the low-hanging fruit

## Estimated Effort by Priority
- **Priority 1**: 1-2 hours (fix ShellCheck + strict mode)
- **Priority 2**: 30-45 minutes
- **Priority 3**: 1-2 hours (test development and edge cases)
- **Priority 4**: 1-3 hours (refactoring file listing and language definitions)
- **Priority 5**: 5-10 minutes
