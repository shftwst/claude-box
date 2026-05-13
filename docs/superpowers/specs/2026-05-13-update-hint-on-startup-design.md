# Update hint on startup — design

## Problem

`claude-box --upgrade` (added in `2a9f17f`) lets the user pull the latest install dir, but there's no surface that tells them an update *exists*. The hint has to be unobtrusive and add zero perceptible latency to launch.

## Approach

Background-checked, daily-cached. The launch path only reads two tiny cache files — never the network. The actual `git fetch` happens detached, after the container has already started, so it can't slow anything down.

## Cache files

Both live under `~/.claude-box/` (sibling to the existing `state/` dir and `.built` marker):

- `.last-update-check` — mtime = timestamp of the last *successful* check. Content is unused.
- `.update-available` — exists iff the last successful check found `HEAD` behind `@{u}`. Content is unused.

Using file existence + mtime (rather than parsing content) keeps the read path branch-free and avoids cross-platform `stat` flag issues.

## Launch flow

Added near the top of `claude-box`, **after** `CLAUDE_BOX_DIR` is resolved and **after** the `--upgrade` short-circuit (so `--upgrade` itself doesn't trigger a check before pulling).

1. **Print hint if cached:**
   ```bash
   [[ -e "$UPDATE_AVAILABLE_FILE" ]] && \
     log "update available — run 'claude-box --upgrade' to pull latest"
   ```
   Uses the existing `log()` helper, which is already gated on `[[ -t 2 ]]` so piped/non-interactive runs stay clean.

2. **Kick off background check if stale:**
   Staleness test uses `find -mtime -1` (portable across macOS BSD-find and GNU find):
   ```bash
   if [[ ! -f "$UPDATE_CHECK_FILE" ]] || \
      [[ -z "$(find "$UPDATE_CHECK_FILE" -mtime -1 2>/dev/null)" ]]; then
     check_for_update_in_background
   fi
   ```

3. **Background check body** runs in a detached subshell:
   ```bash
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
   ```

   Each early-exit is a silent skip (not a git repo, no upstream, fetch failed). On any silent skip, `$UPDATE_CHECK_FILE` is **not** touched — so we'll retry next launch instead of going dark for 24h after a transient offline blip.

## `--upgrade` flow

After `git pull --ff-only` succeeds, clear the cached hint and reset the timestamp so the next launch is quiet:

```bash
if git -C "$CLAUDE_BOX_DIR" pull --ff-only; then
  rm -f "$UPDATE_AVAILABLE_FILE"
  touch "$UPDATE_CHECK_FILE"
  exit 0
else
  exit $?
fi
```

If the pull fails (dirty tree, non-fast-forward), we leave the cache untouched and exit with git's status — same behavior as today.

## Edge cases

| Case | Behavior |
|---|---|
| Install dir isn't a git repo | Silent skip, no retry storm (will keep retrying on each launch since `.last-update-check` never gets written, but it's fast and detached) |
| No upstream configured (`@{u}` fails) | Silent skip |
| Offline / `git fetch` fails | Silent skip, retries next launch |
| `find` unavailable | Falls into the "stale" branch (kicks off check), which is the safe default |
| User runs `--upgrade` and pull fails | Cache untouched; if a previous check had set `.update-available`, hint stays on (correct — they're still behind) |
| Background check overlaps with another claude-box launch | Both will `touch` the same files; harmless — the operations are idempotent |
| Container exits before background check finishes | `disown` detaches the subshell from the parent shell's job control so it keeps running on the host |

## What this is *not* doing (YAGNI)

- No commit summary in the hint — user can `git log` if curious.
- No "N commits behind" count — binary "available / not" is enough to motivate `--upgrade`.
- No opt-out flag — the hint is one line, easy to ignore, and disappears after `--upgrade`. If a user objects, we add a flag then.
- No image-rebuild prompt — the existing `BUILT_MARKER` mtime check already handles rebuilds on the next launch after `--upgrade`.

## Files touched

- `claude-box` — only file modified.

## Testing

Manual:
1. `rm -f ~/.claude-box/.last-update-check ~/.claude-box/.update-available` then launch → no hint, background check fires.
2. Wait a few seconds → `.last-update-check` exists, `.update-available` exists iff actually behind.
3. Launch again → hint prints (if behind), no new check (timestamp <24h).
4. `claude-box --upgrade` → pull runs, `.update-available` removed, `.last-update-check` updated.
5. Next launch → no hint.
6. `cd ~/claude-box && git reset --hard HEAD~1` (simulate being behind) and `touch -t 202001010000 ~/.claude-box/.last-update-check` → relaunch triggers a fresh check, hint appears next launch.
