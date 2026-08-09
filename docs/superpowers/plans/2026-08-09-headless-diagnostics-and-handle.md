# Headless Diagnostics and Addressable Box Handle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-box` warnings survive a non-terminal stderr, and give a headless caller an addressable handle (`--name` / `--name-file`) on the box it started.

**Architecture:** Add a `warn()` helper (unconditional on the tty, like the existing `fault()`) and route the four genuine launcher warnings through it. Add `--name` / `--name-file` as claude-box's own flags in the existing option loop; `--name` overrides the default PID-based container name, `--name-file` publishes the resolved name to a path just before launch and removes it on exit.

**Tech Stack:** POSIX-ish bash (the `claude-box` launcher), docker CLI. No unit-test framework in this repo — gates are `bash -n` and the manual runbook (`docs/runbook-headless-exit.md`).

## Global Constraints

- No em dashes in code comments or docs copy; use commas/colons or split sentences. (Repo AGENTS.md rule.)
- Never use `log()` for anything that must reach a headless caller — `log()` is tty-gated by design. Use `warn()` (warnings) or `fault()` (launcher faults).
- Warnings and faults go to **stderr**, never stdout — the exit-status work guarantees a redirected stdout carries only the harness's output.
- claude-box's own flags are parsed in the loop at `claude-box:107-127` and stripped from `"$@"` before forwarding to `claude`; the `--` escape hatch forwards a same-named claude flag verbatim.
- Docker container-name charset: `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`.
- Match sibling-flag conventions: bad flag usage prints `[claude-box] <msg>` to stderr and `exit 1` (see `--ollama` / `--engine`).
- After every edit: `bash -n claude-box && bash -n entrypoint.sh` must pass.

---

### Task 1: `warn()` channel — warnings survive headless

**Files:**
- Modify: `claude-box:71-77` (add `warn()` after `fault()`), `claude-box:523`, `claude-box:531-534`, `claude-box:543-544`, `claude-box:720`

**Interfaces:**
- Produces: `warn <text>` — prints `[claude-box] WARNING: <text>` to stderr unconditionally (used by later routing and by `--name-file` in Task 3).

- [ ] **Step 1: Baseline check — confirm warnings are currently tty-gated**

Run: `grep -n 'log "WARNING\|log "warning' claude-box`
Expected: four regions match (523, 531-534, 543-544, 720) — all routed through the tty-gated `log()`.

- [ ] **Step 2: Add the `warn()` helper**

Immediately after the `fault()` definition (ends at `claude-box:77`), add:

```sh
# Machine-facing WARNING line. Like fault(), UNCONDITIONAL on the tty: a headless
# caller (CI, a supervisor) relies on these to explain why a rootless engine or
# SSH relay didn't come up, which log() would silently drop when stderr is not a
# terminal. Goes to stderr, so a redirected stdout still carries only the
# harness's output. Interactive runs print the identical line (warn() ignores the
# tty), so headless and interactive stderr match verbatim.
warn() { printf '[claude-box] WARNING: %s\n' "$*" >&2; }
```

- [ ] **Step 3: Route the userns-unsupported block through `warn()`**

At `claude-box:531-534`, replace the four `log "WARNING: …"` lines (drop the now-redundant `WARNING:` prefix, `warn()` adds it):

```sh
        warn "this docker host cannot give an unprivileged user a capable user"
        warn "namespace, so the rootless nested engine will likely fail to start."
        warn "consider sysbox, or '--engine privileged-dind' (ADR-0041's named"
        warn "weaker posture), or '--engine none'."
```

- [ ] **Step 4: Route the remaining three warning sites through `warn()`**

- `claude-box:523`: `_load_userns_profile || warn "apparmor profile load failed — engine may not start"`
- `claude-box:543-544`:
  ```sh
    warn "--engine privileged-dind is ADR-0041's named weaker posture:"
    warn "a privileged cage weakens host isolation. Prefer sysbox or rootless."
  ```
  (Note: the original line 543 ends with an em dash; the replacement uses a colon per the no-em-dash rule.)
- `claude-box:720`: `warn "SSH agent relay failed to start — signing will not work"` becomes `warn "SSH agent relay failed to start: signing will not work"` (drop `warning:` prefix and the em dash).

- [ ] **Step 5: Verify no genuine warning still uses `log()`, and parse is clean**

Run: `grep -n 'log "WARNING\|log "warning' claude-box; bash -n claude-box && echo "parse OK"`
Expected: the grep prints nothing (all four routed), `parse OK`.

- [ ] **Step 6: Commit**

```bash
git add claude-box
git commit -m "feat: route launcher warnings through an unconditional warn()"
```

---

### Task 2: `--name` flag — caller-supplied container name

**Files:**
- Modify: `claude-box:102-128` (declare `BOX_NAME`, parse `--name`, validate after loop), `claude-box:195` (resolve `CONTAINER_NAME`)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `BOX_NAME` (string, empty when `--name` absent); `CONTAINER_NAME` now resolves from it (consumed by Task 3's name-file write, already used at `claude-box:263-264`, `1076`).

- [ ] **Step 1: Declare `BOX_NAME` and parse `--name` in the option loop**

At `claude-box:102-106`, add `BOX_NAME=""` alongside `NO_SSH=0` etc. In the `case` at `claude-box:108-125`, add before the `*)` catch-all:

```sh
    --name)
      shift
      BOX_NAME="${1:-}"
      [[ -n "$BOX_NAME" ]] || { printf '[claude-box] --name requires a container name\n' >&2; exit 1; }
      ;;
    --name=*) BOX_NAME="${1#*=}" ;;
```

- [ ] **Step 2: Validate the name after the loop**

Immediately after the loop's `set -- "${_passthrough[@]+"${_passthrough[@]}"}"` (`claude-box:128`), add:

```sh
# A caller-supplied box name must satisfy docker's container-name charset;
# reject early (before any docker call) with a precise message rather than
# letting `docker run --name` fail obscurely mid-launch. Pre-flight usage error,
# so exit 1 like the sibling flags, not the run-time fault()/125-127 path.
if [[ -n "$BOX_NAME" && ! "$BOX_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  printf '[claude-box] --name: invalid container name (allowed: [a-zA-Z0-9][a-zA-Z0-9_.-]*)\n' >&2
  exit 1
fi
```

- [ ] **Step 3: Resolve `CONTAINER_NAME` from `BOX_NAME`**

At `claude-box:195`, replace:

```sh
CONTAINER_NAME="claude-box-$(basename "$PROJECT_DIR")-$$"
```

with:

```sh
# A caller-supplied --name wins; otherwise the default stays unique per launcher
# via the PID, so concurrent boxes never collide.
CONTAINER_NAME="${BOX_NAME:-claude-box-$(basename "$PROJECT_DIR")-$$}"
```

- [ ] **Step 4: Behavioral test — a bad `--name` is rejected before docker**

Run:
```bash
bash -n claude-box && \
( cd "$(mktemp -d)" && git init -q && "$OLDPWD/claude-box" --name 'a b/c' >/dev/null 2>err.txt; echo "exit=$?"; cat err.txt )
```
Expected: `exit=1` and stderr contains `[claude-box] --name: invalid container name`. No docker build or run happens (the reject is in the option loop, well before `claude-box:206`).

- [ ] **Step 5: Behavioral test — the empty-value form is rejected**

Run: `( cd "$(mktemp -d)" && git init -q && "$OLDPWD/claude-box" --name >/dev/null 2>err.txt; echo "exit=$?"; grep -q 'requires a container name' err.txt && echo MSG_OK )`
Expected: `exit=1`, `MSG_OK`.

- [ ] **Step 6: Commit**

```bash
git add claude-box
git commit -m "feat: add --name to set the box's container name"
```

---

### Task 3: `--name-file` flag — publish the resolved name for a headless caller

**Files:**
- Modify: `claude-box:102-125` (declare `NAME_FILE`, parse `--name-file`), `claude-box:233-238` (`cleanup()` removes the file), `claude-box:1073` region (write the file just before `docker run`)

**Interfaces:**
- Consumes: `CONTAINER_NAME` (Task 2), `warn()` (Task 1).
- Produces: `NAME_FILE` (string, empty when absent). No later task depends on it.

- [ ] **Step 1: Declare `NAME_FILE` and parse `--name-file`**

At `claude-box:102-106`, add `NAME_FILE=""`. In the `case`, add before `*)`:

```sh
    --name-file)
      shift
      NAME_FILE="${1:-}"
      [[ -n "$NAME_FILE" ]] || { printf '[claude-box] --name-file requires a path\n' >&2; exit 1; }
      ;;
    --name-file=*) NAME_FILE="${1#*=}" ;;
```

- [ ] **Step 2: Write the resolved name just before `docker run`**

At the `_LAUNCHED=1` line (`claude-box:1073`), immediately after it and before the `docker run` invocation, add:

```sh
# Publish the box's name for a headless caller to address (docker stop/exec).
# Written HERE — just before the container exists and inside the EXIT-trap
# coverage (trap set at the sync_back/cleanup line above) — so the file's
# lifetime matches the box's: cleanup() removes it on exit, and the container is
# --rm so a post-exit handle would be dead anyway. A caller that only passes
# --name-file polls for this file to appear, then reads the name.
if [[ -n "$NAME_FILE" ]]; then
  printf '%s\n' "$CONTAINER_NAME" > "$NAME_FILE" \
    || warn "--name-file: could not write ${NAME_FILE}"
fi
```

- [ ] **Step 3: Remove the file in `cleanup()`**

In `cleanup()` (`claude-box:233-238`), add before the closing `}`:

```sh
  [[ -n "$NAME_FILE" ]] && rm -f "$NAME_FILE"
```

- [ ] **Step 4: Behavioral test — `--name-file` parses and the empty form is rejected**

Run: `bash -n claude-box && ( cd "$(mktemp -d)" && git init -q && "$OLDPWD/claude-box" --name-file >/dev/null 2>err.txt; echo "exit=$?"; grep -q 'requires a path' err.txt && echo MSG_OK )`
Expected: `parse OK` (implied by no error), `exit=1`, `MSG_OK`.

- [ ] **Step 5: Commit**

```bash
git add claude-box
git commit -m "feat: add --name-file to publish the box name for headless callers"
```

---

### Task 4: Documentation — header block, runbook, README

**Files:**
- Modify: `claude-box` header comment (the exit-status contract block, ~`claude-box:45-62`), `docs/runbook-headless-exit.md`, `README` (the flag/usage list)

**Interfaces:**
- Consumes: the behaviors from Tasks 1-3. Produces: no code.

- [ ] **Step 1: Document the two flags in the claude-box header block**

In the header comment block that already documents the exit-status contract, add a short section:

```sh
# Addressing a headless box:
#   --name <name>       set the container name (default: claude-box-<project>-<pid>).
#                       Must match docker's charset [a-zA-Z0-9][a-zA-Z0-9_.-]*.
#   --name-file <path>  write the resolved name to <path> just before launch and
#                       remove it on exit. A supervisor polls <path>, reads the
#                       name, then `docker stop`/`docker exec` the box.
```

- [ ] **Step 2: Add a "warnings survive headless" part to the runbook**

Append to `docs/runbook-headless-exit.md` a part that asserts warn() output is tty-independent, e.g.:

```markdown
## Part 4 — Warnings survive a non-terminal stderr

Warnings must reach captured stderr headless, identically to an interactive run.
Force the userns-unsupported path (or any warn() site) and capture stderr:

```sh
# On a host whose userns probe resolves `unsupported`, or with the strategy
# cache primed to it: rm -f ~/.claude-box/.userns-strategy-*; echo unsupported > ~/.claude-box/.userns-strategy-<docker-host-slug>
claude-box --engine rootless -- --version >out.txt 2>err.txt || true
grep -q '\[claude-box\] WARNING: this docker host cannot' err.txt && echo "WARN_HEADLESS_OK"
```

Expected: `WARN_HEADLESS_OK`. The same line appears on an interactive run's terminal.
```

- [ ] **Step 3: Add a "start headless → read name → stop" part to the runbook**

Append a part that exercises the handle via the existing `CLAUDE_BOX_EXEC` hook:

```markdown
## Part 5 — Address a box started headless

```sh
h="$(mktemp)"
CLAUDE_BOX_EXEC=1 claude-box --name-file "$h" -- sleep 300 >/dev/null 2>&1 &
launcher=$!
# Poll for the launcher to publish the name (it appears just before the box starts).
for i in $(seq 1 100); do [ -s "$h" ] && break; sleep 0.1; done
name="$(cat "$h")"; echo "handle=$name"
docker exec "$name" true && echo "EXEC_OK"
docker stop "$name" >/dev/null && echo "STOP_OK"
wait "$launcher" 2>/dev/null
[ -e "$h" ] || echo "NAME_FILE_CLEANED"
```

Expected: `handle=…`, `EXEC_OK`, `STOP_OK`, `NAME_FILE_CLEANED`.
```

- [ ] **Step 4: Add both flags to the README usage/flag list**

In `README` where `--no-ssh` / `--engine` / `--ollama` are listed, add:

```markdown
- `--name <name>` — name the box's container (default `claude-box-<project>-<pid>`); lets a caller address it with `docker stop`/`docker exec`.
- `--name-file <path>` — write the resolved container name to `<path>` just before launch (removed on exit), so a headless supervisor can discover and stop the box.
```

- [ ] **Step 5: Verify docs reference real behavior and commit**

Run: `grep -n 'name-file\|--name ' README docs/runbook-headless-exit.md claude-box | head`
Expected: matches in all three files.

```bash
git add claude-box README docs/runbook-headless-exit.md
git commit -m "docs: document --name/--name-file and headless-warning acceptance"
```

---

## Self-Review

**Spec coverage:**
- Goal 1 (warnings survive headless) → Task 1 + runbook Part 4 (Task 4 Step 2). ✓
- Goal 2 (addressable handle) → Task 2 (`--name`) + Task 3 (`--name-file`) + runbook Part 5 (Task 4 Step 3). ✓
- Spec §1 warn() + four sites → Task 1. ✓
- Spec §2 `--name` parse/validate/resolve → Task 2; `--name-file` write/cleanup/unwritable→warn → Task 3. ✓
- Spec §3 docs (header, runbook, README) → Task 4. ✓
- Spec §4 acceptance (bash -n, diagnostics, handle, `--name` validation) → per-task `bash -n` + Task 2 Steps 4-5 + Task 4 Parts 4-5. ✓

**Placeholder scan:** No TBD/TODO; every code step shows exact old→new text. ✓

**Type/name consistency:** `warn` (Task 1) used in Tasks 3-4. `BOX_NAME` → `CONTAINER_NAME` (Task 2) consumed by Task 3's write and the existing `docker run --name`. `NAME_FILE` declared/parsed (Task 3 Step 1), written (Step 2), removed (Step 3). Consistent. ✓

**Note on testing:** Tasks 1 and 3's docker-dependent behavior (warn on a real unsupported host; the name-file write/cleanup during an actual run) is verified through the runbook, since the repo has no docker-free way to exercise a launch. Tasks 2's validation and the empty-value rejections ARE exercised docker-free because they reject inside the option loop before any docker call.
