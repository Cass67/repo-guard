# .gitignore OS and editor coverage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add broad OS and editor junk exclusions to both tracked `.gitignore` files without changing the existing secret-handling rules.

**Architecture:** Apply the same labeled ignore block to the repository root `.gitignore` and the install template `.gitignore` so the repo stays internally consistent and generated repos inherit the same defaults. Keep the change scoped to safe OS/editor noise only.

**Tech Stack:** Git ignore files, patch-based file edits, shell verification

---

### Task 1: Update root `.gitignore`

**Files:**
- Modify: `.gitignore`

**Step 1: Write the failing test**

Define the expected lines that are currently missing from `.gitignore`:

```text
.DS_Store
.vscode/
Thumbs.db
```

**Step 2: Run test to verify it fails**

Run: `rg -n "^(\.DS_Store|\.vscode/|Thumbs\.db)$" .gitignore`
Expected: missing one or more expected entries

**Step 3: Write minimal implementation**

Add a labeled OS/editor junk block with the approved entries.

**Step 4: Run test to verify it passes**

Run: `rg -n "^(\.DS_Store|\.vscode/|Thumbs\.db)$" .gitignore`
Expected: all expected entries reported

**Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: expand gitignore for OS editor files"
```

### Task 2: Update template `.gitignore`

**Files:**
- Modify: `templates/repo-guard/.gitignore`

**Step 1: Write the failing test**

Define the expected lines that are currently missing from `templates/repo-guard/.gitignore`:

```text
.DS_Store
.vscode/
Thumbs.db
```

**Step 2: Run test to verify it fails**

Run: `rg -n "^(\.DS_Store|\.vscode/|Thumbs\.db)$" templates/repo-guard/.gitignore`
Expected: missing one or more expected entries

**Step 3: Write minimal implementation**

Add the same labeled OS/editor junk block used in the root file.

**Step 4: Run test to verify it passes**

Run: `rg -n "^(\.DS_Store|\.vscode/|Thumbs\.db)$" templates/repo-guard/.gitignore`
Expected: all expected entries reported

**Step 5: Commit**

```bash
git add templates/repo-guard/.gitignore
git commit -m "chore: expand template gitignore defaults"
```

### Task 3: Verify consistency across both files

**Files:**
- Modify: `.gitignore`
- Modify: `templates/repo-guard/.gitignore`

**Step 1: Write the failing test**

Define the required shared entries:

```text
.DS_Store
.vscode/
.idea/
Thumbs.db
*.swp
```

**Step 2: Run test to verify it fails**

Run: `for f in .gitignore templates/repo-guard/.gitignore; do echo "== $f =="; rg -n "^(\.DS_Store|\.vscode/|\.idea/|Thumbs\.db|\*\.swp)$" "$f"; done`
Expected: at least one file misses one or more required entries before editing

**Step 3: Write minimal implementation**

Align both files so the OS/editor block matches.

**Step 4: Run test to verify it passes**

Run: `for f in .gitignore templates/repo-guard/.gitignore; do echo "== $f =="; rg -n "^(\.DS_Store|\.vscode/|\.idea/|Thumbs\.db|\*\.swp)$" "$f"; done`
Expected: all listed entries appear in both files

**Step 5: Commit**

```bash
git add .gitignore templates/repo-guard/.gitignore
git commit -m "chore: add OS and editor junk gitignore rules"
```
