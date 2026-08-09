# Headless diagnostics and an addressable box handle

## Problem

Two gaps make `claude-box` hard to drive from a script, CI job, or supervisor —
exactly the callers the recent headless exit-status work was meant to serve.

1. **Diagnostics vanish when stderr is not a terminal.** The launcher's `log()`
   is `[[ ! -t 2 ]] || printf …` — every line it emits is suppressed unless
   stderr is a tty. Headless, that discards the warnings that matter most:
   - the userns-unsupported block (`claude-box:531-534`) — "this docker host
     cannot give an unprivileged user a capable user namespace, so the rootless
     nested engine will likely fail to start";
   - the apparmor-profile-load failure (`claude-box:523`);
   - the privileged-dind weaker-posture notice (`claude-box:543-544`);
   - the SSH-agent-relay failure (`claude-box:720`).

   So a rootless engine that fails to come up does so with no launcher-side
   explanation — the one thing a CI log exists to provide.

2. **A headless caller has no handle on the box it started.** `CONTAINER_NAME`
   (`claude-box:195`) embeds the launcher's PID and is passed to
   `docker run --name`, but a caller has no supported way to learn it, so it
   cannot `docker stop` or `docker exec` the box it launched.

## Goals

- A warning printed on an interactive run also reaches captured stderr on a
  headless run, verbatim.
- A caller can start a box headless, obtain its container name from a documented
  place, and `docker stop` / `docker exec` it.

## Non-goals (YAGNI)

- No `docker ps` parsing or name-guessing.
- No handle for the *inner* nested engine — only the outer session container.
- No structured/JSON status output.
- No new exit codes; the existing contract (0 / 1-124 / 125-127 / 128+) stands.

## Design

### 1. `warn()` — diagnostics unconditional on the tty

Add a sibling to the existing `fault()` helper:

```sh
warn() { printf '[claude-box] WARNING: %s\n' "$*" >&2; }
```

- **Unconditional on the tty**, like `fault()`. It must reach captured stderr
  whether or not stderr is a terminal.
- **Writes to stderr**, so the clean-stdout capture contract from the
  exit-status work is preserved — a redirected stdout still carries only the
  harness's output.

Route the four genuine warnings through `warn()`, dropping their now-redundant
inline `WARNING:` / `warning:` prefixes:

| Site | Current | Becomes |
| --- | --- | --- |
| `claude-box:531-534` | 4× `log "WARNING: …"` (userns unsupported) | 4× `warn "…"` |
| `claude-box:523` | `log "WARNING: apparmor profile load failed …"` | `warn "apparmor profile load failed …"` |
| `claude-box:543-544` | 2× `log "WARNING: --engine privileged-dind …"` | 2× `warn "--engine privileged-dind …"` |
| `claude-box:720` | `log "warning: SSH agent relay failed …"` | `warn "SSH agent relay failed …"` |

Informational `log()` calls (`building image…`, `starting container…`, the
`engine:` / userns-strategy lines) stay tty-gated, so a headless capture gets
warnings only, not progress noise.

Because `warn()` also prints on a tty, an interactive run and a headless run
emit the **identical** warning text — that is precisely the acceptance check.
Interactive output is otherwise unchanged.

### 2. Addressable handle — `--name` and `--name-file`

Both are claude-box's own flags, parsed in the existing option loop
(`claude-box:107-127`) alongside `--ollama` / `--engine`, matching their
`--flag value` and `--flag=value` shapes. They are stripped from `"$@"` before
the remainder is forwarded to `claude`. The existing `--` escape hatch
(`claude-box:99-101`) already covers the unlikely day `claude` grows its own
`--name`: `claude-box -- --name foo` forwards it verbatim.

**`--name <name>` / `--name=<name>`** — caller-supplied container name.

- Default is unchanged: `claude-box-$(basename "$PROJECT_DIR")-$$` (still unique
  across concurrent boxes via the PID).
- Resolution at `claude-box:195` becomes:
  `CONTAINER_NAME="${_cli_name:-claude-box-$(basename "$PROJECT_DIR")-$$}"`
  where `_cli_name` is the parsed flag value (empty when not given).
- Validated against docker's container-name charset
  `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`. On a bad value:
  `printf '[claude-box] --name: invalid container name (allowed: [a-zA-Z0-9][a-zA-Z0-9_.-]*)\n' >&2; exit 1`
  — matching how `--ollama` / `--engine` reject bad args (plain `[claude-box]`
  message, `exit 1`, already headless-safe). This pre-flight usage error
  deliberately uses `exit 1` rather than the run-time `fault()` / 125-127 path,
  consistent with its sibling flags.

**`--name-file <path>` / `--name-file=<path>`** — where to publish the resolved
name.

- Write the resolved `CONTAINER_NAME` (caller-supplied or auto) to `<path>`
  **just before `docker run`** (the `_LAUNCHED=1` region, ~`claude-box:1073`):
  `printf '%s\n' "$CONTAINER_NAME" > "$_name_file"`.
  - This point is chosen so the file appears exactly when the container is about
    to exist, and it is inside the EXIT-trap coverage (the trap is installed at
    `claude-box:352`, before the run). Writing earlier (e.g. at arg-parse time)
    would publish a handle before any container exists, and — on an early
    `exit 125` from the pre-run image checks, which run before the trap is set —
    would strand a stale file.
- Remove it in `cleanup()` (`claude-box:233`): the container is `--rm`, so once
  the box exits the name addresses nothing; the file's lifetime matches the
  box's.
- If `<path>` is unwritable: `warn "--name-file: could not write <path>"` and
  continue. Losing the handle does not justify failing the run.

**How the two compose.** `--name` is for a caller that wants to choose the
handle (it already knows the name; no read-back needed). `--name-file` is for a
caller that wants the launcher to own uniqueness and then read the auto-name
back. Supplying both is allowed and simply writes the caller's chosen name to
the file. A caller that only sets `--name-file` polls for the file to appear,
reads the name, then stops/execs the box.

### 3. Documentation

- **claude-box header block** — document `--name` and `--name-file` next to the
  exit-status contract.
- **`docs/runbook-headless-exit.md`** — add two parts: (a) *warnings survive
  headless* — force the userns-unsupported path and assert the warning is in
  captured stderr; (b) *start headless → read name → stop* — launch with
  `--name-file`, poll for it, `docker stop` the box.
- **README** — add both flags to the flag/usage list.

## Testing / acceptance

- `bash -n claude-box && bash -n entrypoint.sh` parses clean (the repo's static
  gate).
- **Diagnostics (goal 1):** on a host where the userns probe resolves
  `unsupported`, a headless run's captured stderr contains the same
  `[claude-box] WARNING: this docker host cannot …` line an interactive run
  prints. (The runbook forces this path; where a real unsupported host isn't
  available, the assertion is that `warn()` output is tty-independent.)
- **Handle (goal 2):** using the existing `CLAUDE_BOX_EXEC` hook to hold a box
  open, `--name-file /tmp/h` publishes the name, a poll reads it, and
  `docker stop "$(cat /tmp/h)"` stops the box; the file is gone afterward.
- **`--name` validation:** a bad `--name 'a b/c'` exits 1 with the
  `[claude-box] --name: invalid …` message and starts no container; a valid
  `--name my-box` is the container's name under `docker ps`.

## Files touched

- `claude-box` — `warn()` helper; four warning sites re-routed; `--name` /
  `--name-file` parsing, validation, resolution, name-file write, cleanup;
  header-block docs.
- `docs/runbook-headless-exit.md` — two new acceptance parts.
- `README` — two new flags.
