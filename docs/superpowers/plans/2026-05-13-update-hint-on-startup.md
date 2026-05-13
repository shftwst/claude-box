# Update Hint on Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-line hint at launch that nudges the user toward `claude-box --upgrade` when the install dir is behind upstream, with zero added launch latency.

**Architecture:** Background-checked, daily-cached. Launch path reads two tiny cache files in `~/.claude-box/` (`.last-update-check` mtime + `.update-available` existence). When the cached timestamp is >24h old or missing, a detached subshell runs `git fetch` and updates the cache. The `--upgrade` flow clears the cache on successful pull.

**Tech Stack:** Bash 4+, `git`, `find` (BSD/GNU compatible), `disown`. No new dependencies.

**Spec:** [`2026-05-13-update-hint-on-startup-design.md`](../specs/2026-05-13-update-hint-on-startup-design.md)

**Note on testing:** `claude-box` has no test harness (no bats, no shellcheck wiring). Each task ends with a manual verification step that runs the actual command and inspects the result. This is honest given the project's current state — adding a test framework just for this feature is YAGNI.

---

## File Structure

Only one file is touched: `claude-box` (the launcher script).

The change adds ~30 lines in four logical regions, all on the host side (before `docker run`):

1. **Variable declarations** (near `BUILT_MARKER`, ~line 76)
2. **`check_for_update_in_background` function** (new helper, alongside `log()` near top)
3. **Launch-flow hook** (after `CLAUDE_BOX_DIR` resolution and `--upgrade` short-circuit, before `PROJECT_DIR` setup)
4. **`--upgrade` flow update** (modifies the existing block at ~lines 65-69)

---

### Task 1: Add cache file variables and ensure parent dir exists

**Files:**
- Modify: `claude-box` (insert after `CLAUDE_BOX_DIR` resolution at line 60, before the `--upgrade` short-circuit at line 65)

Add the two cache file paths *above* the `--upgrade` block — Task 4 will use these variables inside that block, so they must be defined first. We deliberately don't put them next to `BUILT_MARKER` (line 76) because the `--upgrade` short-circuit returns before line 76 ever runs. Also add an unconditional `mkdir -p` so the read/write paths below don't fail on a fresh host (the existing `mkdir` at line 92 is gated on the image-build branch).

- [ ] **Step 1: Add variable declarations**

Find this region in `claude-box` (around lines 60-65):

```bash
CLAUDE_BOX_DIR="$(cd "$(dirname "$_self")" && pwd)"

# --upgrade: pull latest claude-box and exit. Next regular run picks up any
# Dockerfile/entrypoint changes via the mtime-vs-BUILT_MARKER check below.
# Uses --ff-only so a dirty install dir errors out instead of silently merging.
if [[ $UPGRADE -eq 1 ]]; then
```

Insert the three new lines between `CLAUDE_BOX_DIR=...` and the `# --upgrade:` comment:

```bash
CLAUDE_BOX_DIR="$(cd "$(dirname "$_self")" && pwd)"

UPDATE_CHECK_FILE="${HOME}/.claude-box/.last-update-check"
UPDATE_AVAILABLE_FILE="${HOME}/.claude-box/.update-available"
mkdir -p "${HOME}/.claude-box"

# --upgrade: pull latest claude-box and exit. Next regular run picks up any
# Dockerfile/entrypoint changes via the mtime-vs-BUILT_MARKER check below.
# Uses --ff-only so a dirty install dir errors out instead of silently merging.
if [[ $UPGRADE -eq 1 ]]; then
```

- [ ] **Step 2: Verify script still parses**

Run: `bash -n /Users/shftwst/workspace/shftwst/claude-box/claude-box`
Expected: no output (exit 0). Any syntax error here means the edit went wrong.

- [ ] **Step 3: Verify cache parent dir gets created**

Run:
```bash
rm -rf /tmp/claude-box-home-test && HOME=/tmp/claude-box-home-test bash -c 'mkdir -p "${HOME}/.claude-box" && ls -la "${HOME}/.claude-box"'
```
Expected: directory exists, owned by current user.

- [ ] **Step 4: Commit**

```bash
git add claude-box
git commit -m "feat: declare update-check cache file paths"
```

---

### Task 2: Add `check_for_update_in_background` helper function

**Files:**
- Modify: `claude-box` (insert after the `log()` definition at line 37)

Define the function that does the actual `git fetch` and cache update. It's a detached subshell so the parent never waits and stderr/stdout are swallowed. Each early exit is a silent skip — we don't want to spam the user with "your install dir isn't a git repo" warnings.

Placing it next to `log()` keeps all the top-level helper definitions together.

- [ ] **Step 1: Add the function definition**

Find this line in `claude-box`:

```bash
log() { [[ -t 2 ]] && printf '[claude-box] %s\n' "$*" >&2; }
```

Add directly below it:

```bash
# Background-check the install dir against its upstream. Detached so the parent
# never waits and silent on every failure mode (not a repo, no upstream,
# offline, fetch fails) — those skips don't touch $UPDATE_CHECK_FILE so we
# retry next launch instead of going dark for 24h on a transient blip.
check_for_update_in_background() {
  (
    cd "$CLAUDE_BOX_DIR" || exit 0
    git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || exit 0
    git fetch --quiet 2>/dev/null || exit 0
    if [[ $(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0) -gt 0 ]]; then
      touch "$UPDATE_AVAILABLE_FILE"
    else
      rm -f "$UPDATE_AVAILABLE_FILE"
    fi
    touch "$UPDATE_CHECK_FILE"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
```

- [ ] **Step 2: Verify script still parses**

Run: `bash -n /Users/shftwst/workspace/shftwst/claude-box/claude-box`
Expected: no output (exit 0).

- [ ] **Step 3: Smoke-test the function in isolation**

Run from the claude-box repo root:
```bash
HOME=/tmp/claude-box-home-test
mkdir -p "$HOME/.claude-box"
CLAUDE_BOX_DIR="/Users/shftwst/workspace/shftwst/claude-box"
UPDATE_CHECK_FILE="$HOME/.claude-box/.last-update-check"
UPDATE_AVAILABLE_FILE="$HOME/.claude-box/.update-available"
check_for_update_in_background() {
  (
    cd "$CLAUDE_BOX_DIR" || exit 0
    git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || exit 0
    git fetch --quiet 2>/dev/null || exit 0
    if [[ $(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0) -gt 0 ]]; then
      touch "$UPDATE_AVAILABLE_FILE"
    else
      rm -f "$UPDATE_AVAILABLE_FILE"
    fi
    touch "$UPDATE_CHECK_FILE"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
check_for_update_in_background
sleep 3
ls -la "$HOME/.claude-box/"
```

Expected: `.last-update-check` is present (proves the fetch + touch ran). `.update-available` may or may not be present depending on whether the local branch is behind upstream — both are valid outcomes.

- [ ] **Step 4: Commit**

```bash
git add claude-box
git commit -m "feat: add background update-check helper for claude-box install dir"
```

---

### Task 3: Print hint and trigger staleness check on launch

**Files:**
- Modify: `claude-box` (insert after the `--upgrade` short-circuit at line 69, before `PROJECT_DIR` setup at line 71)

This is the user-facing piece. Reading `.update-available` is O(1) with no network, and the staleness check uses `find -mtime -1` which works on both BSD `find` (macOS) and GNU `find` (Linux). When stale, it calls the function from Task 2 — which detaches and returns immediately.

Placement matters: this must run *after* the `--upgrade` block so `claude-box --upgrade` doesn't trigger a redundant check before pulling.

- [ ] **Step 1: Add the hint + staleness-check block**

Find this region in `claude-box` (around lines 65-71):

```bash
if [[ $UPGRADE -eq 1 ]]; then
  log "upgrading claude-box at ${CLAUDE_BOX_DIR}..."
  git -C "$CLAUDE_BOX_DIR" pull --ff-only
  exit $?
fi

PROJECT_DIR="$(cd "${1:-$PWD}" && pwd)"
```

Insert between the closing `fi` of the `--upgrade` block and the `PROJECT_DIR` assignment:

```bash
if [[ $UPGRADE -eq 1 ]]; then
  log "upgrading claude-box at ${CLAUDE_BOX_DIR}..."
  git -C "$CLAUDE_BOX_DIR" pull --ff-only
  exit $?
fi

# Show cached update hint (zero-latency: just a file-existence check).
[[ -e "$UPDATE_AVAILABLE_FILE" ]] && \
  log "update available — run 'claude-box --upgrade' to pull latest"

# If our cached check is missing or >24h old, kick off a fresh check in the
# background. `find -mtime -1` is portable across BSD (macOS) and GNU find.
if [[ ! -f "$UPDATE_CHECK_FILE" ]] || \
   [[ -z "$(find "$UPDATE_CHECK_FILE" -mtime -1 2>/dev/null)" ]]; then
  check_for_update_in_background
fi

PROJECT_DIR="$(cd "${1:-$PWD}" && pwd)"
```

Note: this assumes Tasks 1 and 2 are already done — `$UPDATE_AVAILABLE_FILE`, `$UPDATE_CHECK_FILE`, and `check_for_update_in_background` are defined above this point.

- [ ] **Step 2: Verify script still parses**

Run: `bash -n /Users/shftwst/workspace/shftwst/claude-box/claude-box`
Expected: no output (exit 0).

- [ ] **Step 3: Verify the hint prints when `.update-available` exists**

Run:
```bash
touch ~/.claude-box/.update-available
/Users/shftwst/workspace/shftwst/claude-box/claude-box --help 2>&1 | head -5
```

Wait — `claude-box` doesn't have a `--help` flag and will treat `--help` as a project dir. Use a dry-run approach instead: extract just the hint-printing line and run it directly:

```bash
touch ~/.claude-box/.update-available
UPDATE_AVAILABLE_FILE="${HOME}/.claude-box/.update-available"
log() { [[ -t 2 ]] && printf '[claude-box] %s\n' "$*" >&2; }
[[ -e "$UPDATE_AVAILABLE_FILE" ]] && \
  log "update available — run 'claude-box --upgrade' to pull latest"
```

Expected stderr: `[claude-box] update available — run 'claude-box --upgrade' to pull latest`

Then clean up: `rm -f ~/.claude-box/.update-available`

- [ ] **Step 4: Verify staleness detection**

```bash
# Fresh marker → considered current → no check fires
touch ~/.claude-box/.last-update-check
[[ -z "$(find ~/.claude-box/.last-update-check -mtime -1 2>/dev/null)" ]] && echo STALE || echo FRESH
```
Expected: `FRESH`

```bash
# Backdate by 2 days → considered stale → check would fire
touch -t $(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M) ~/.claude-box/.last-update-check
[[ -z "$(find ~/.claude-box/.last-update-check -mtime -1 2>/dev/null)" ]] && echo STALE || echo FRESH
```
Expected: `STALE`

(The `date -v-2d` form is BSD/macOS; `date -d '2 days ago'` is GNU/Linux. The `||` picks whichever works.)

- [ ] **Step 5: Commit**

```bash
git add claude-box
git commit -m "feat: hint at --upgrade on startup when install dir is behind"
```

---

### Task 4: Clear cache after successful `--upgrade`

**Files:**
- Modify: `claude-box:65-69` (the existing `--upgrade` block)

Right now `git pull --ff-only` runs and the script exits with git's status. If the pull succeeds but `.update-available` still exists from a prior check, the next launch will incorrectly print the hint until the daily cache refresh runs. Fix that by clearing the cache on success.

- [ ] **Step 1: Update the `--upgrade` block**

Find this block in `claude-box`:

```bash
if [[ $UPGRADE -eq 1 ]]; then
  log "upgrading claude-box at ${CLAUDE_BOX_DIR}..."
  git -C "$CLAUDE_BOX_DIR" pull --ff-only
  exit $?
fi
```

Replace with:

```bash
if [[ $UPGRADE -eq 1 ]]; then
  log "upgrading claude-box at ${CLAUDE_BOX_DIR}..."
  if git -C "$CLAUDE_BOX_DIR" pull --ff-only; then
    rm -f "$UPDATE_AVAILABLE_FILE"
    touch "$UPDATE_CHECK_FILE"
    exit 0
  else
    exit $?
  fi
fi
```

Note: the `exit $?` in the failure branch captures git's exit code. On pull failure (dirty tree, non-fast-forward), the cache is left untouched — correct, because the user is still behind.

- [ ] **Step 2: Verify script still parses**

Run: `bash -n /Users/shftwst/workspace/shftwst/claude-box/claude-box`
Expected: no output (exit 0).

- [ ] **Step 3: Simulate a successful upgrade and verify cache clears**

```bash
touch ~/.claude-box/.update-available
ls -la ~/.claude-box/.update-available
/Users/shftwst/workspace/shftwst/claude-box/claude-box --upgrade
ls -la ~/.claude-box/.update-available 2>&1 | head -1
ls -la ~/.claude-box/.last-update-check
```
Expected:
- First `ls`: file exists.
- `--upgrade` output: either `Already up to date.` (no commits behind) or fast-forward output.
- Second `ls`: `No such file or directory` (file was removed).
- Third `ls`: file exists, mtime is now.

- [ ] **Step 4: Commit**

```bash
git add claude-box
git commit -m "feat: clear update-available cache after successful --upgrade"
```

---

### Task 5: End-to-end manual verification

**Files:** none modified.

Walks through the user-visible behavior to confirm everything fits together. Each substep maps to a concrete claim in the spec's "Testing" section.

- [ ] **Step 1: Cold start — no cache, no hint, background check fires**

```bash
rm -f ~/.claude-box/.last-update-check ~/.claude-box/.update-available
/Users/shftwst/workspace/shftwst/claude-box/claude-box --upgrade 2>&1 | grep -c 'update available' || true
```

Wait — `--upgrade` short-circuits before the hint logic. We want to trigger a real launch path without actually starting the container. Easiest: invoke the script in a way that fails fast after the hint check. Since the script doesn't have a dry-run, do this instead:

```bash
rm -f ~/.claude-box/.last-update-check ~/.claude-box/.update-available
# Inspect: no hint printed (nothing cached), background fetch kicked off
/Users/shftwst/workspace/shftwst/claude-box/claude-box /nonexistent-dir 2>&1 | head -5
```

The script will fail at `cd "${1:-$PWD}"` because `/nonexistent-dir` doesn't exist — but it will have already executed the hint/staleness block. Expected: no `update available` line in the output. The background check will run asynchronously.

```bash
sleep 3
ls -la ~/.claude-box/.last-update-check
```
Expected: file exists, mtime is now.

- [ ] **Step 2: Warm start (within 24h) — hint prints iff behind, no fresh check**

```bash
# If you happen to be behind upstream, .update-available will exist after step 1.
ls -la ~/.claude-box/.update-available 2>&1 | head -1
```

If `.update-available` exists, launching should print the hint:
```bash
/Users/shftwst/workspace/shftwst/claude-box/claude-box /nonexistent-dir 2>&1 | head -5
```
Expected output includes: `[claude-box] update available — run 'claude-box --upgrade' to pull latest`

- [ ] **Step 3: `--upgrade` clears the hint**

If `.update-available` exists from steps 1-2:
```bash
/Users/shftwst/workspace/shftwst/claude-box/claude-box --upgrade
ls -la ~/.claude-box/.update-available 2>&1 | head -1
```
Expected: `.update-available` gone (`No such file or directory`).

Next launch is silent:
```bash
/Users/shftwst/workspace/shftwst/claude-box/claude-box /nonexistent-dir 2>&1 | grep 'update available' || echo "no hint (correct)"
```
Expected: `no hint (correct)`.

- [ ] **Step 4: Forced stale → re-check fires**

Simulate being behind by rewinding the install dir one commit and backdating the cache:

```bash
cd /Users/shftwst/workspace/shftwst/claude-box
git fetch
git reset --hard HEAD~1  # only if HEAD~1 exists on upstream; skip if it doesn't
touch -t $(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M) ~/.claude-box/.last-update-check
rm -f ~/.claude-box/.update-available

/Users/shftwst/workspace/shftwst/claude-box/claude-box /nonexistent-dir 2>&1 | head -5
sleep 3
ls -la ~/.claude-box/.update-available
```
Expected:
- First launch: no hint yet (cache was empty when we cleared it).
- After sleep: `.update-available` exists (we're 1 commit behind, fetch confirmed it).
- A second launch would now print the hint:
```bash
/Users/shftwst/workspace/shftwst/claude-box/claude-box /nonexistent-dir 2>&1 | head -5
```
Expected: hint prints.

Restore state at end of test:
```bash
cd /Users/shftwst/workspace/shftwst/claude-box
git pull --ff-only
```

- [ ] **Step 5: Offline behavior**

Disconnect from the network (or use `sudo route -n add -host github.com 127.0.0.1` on macOS for a soft test — *remember to undo it*). Then:

```bash
rm -f ~/.claude-box/.last-update-check
/Users/shftwst/workspace/shftwst/claude-box/claude-box /nonexistent-dir 2>&1 | head -5
sleep 5
ls -la ~/.claude-box/.last-update-check 2>&1 | head -1
```
Expected: `.last-update-check` does NOT exist (background `git fetch` failed silently, didn't touch the file → we'll retry next launch).

If you used the route trick: `sudo route -n delete -host github.com` to undo.

- [ ] **Step 6: No commit needed**

This task is verification only. If any substep failed, return to the relevant task above and fix the implementation.

---

## Self-Review Checklist

After implementing all five tasks:

- [ ] Run `bash -n claude-box` — passes.
- [ ] Run `shellcheck claude-box` if installed — review any new warnings on the lines you added.
- [ ] Verify no behavior change when `~/.claude-box/.update-available` does not exist and `.last-update-check` is fresh.
- [ ] Verify launch output is otherwise identical (same `log` lines in same order, except for the optional new hint line).
- [ ] Verify `claude-box --upgrade` still works without the rest of the script having ever run (e.g. on a host where `~/.claude-box/` was just created).
