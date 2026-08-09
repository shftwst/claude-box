# Runbook — headless exit status & clean streams

Verifies the launcher exits with the harness's status, emits machine-readable
fault lines, and keeps redirected streams clean. Maps 1:1 to the ticket's
acceptance criteria.

## Prerequisites

- A **real docker host** (Docker Desktop / OrbStack / Colima / rootless) — run
  these on the host, not inside a box.
- `claude-box` from this branch on `PATH`.
- A throwaway project dir that is **not** `$HOME` (the launcher refuses `$HOME`
  and its ancestors):
  ```sh
  mkdir -p /tmp/cbtest && cd /tmp/cbtest && git init -q
  ```
- The **first run builds images** (`cage-base`, then the `claude-box` payload
  image). Warm them once and ignore the output:
  ```sh
  claude-box -- --version >/dev/null 2>&1 || true
  ```
- Auth (a logged-in Claude) is only needed for the one real-harness smoke in
  Part 3; every other test uses the `CLAUDE_BOX_EXEC` hook and needs no auth.

Two test hooks (both forwarded into the box by this branch):
- `CLAUDE_BOX_EXEC=1 claude-box -- <cmd…>` runs `<cmd…>` as the in-box harness
  instead of `claude`, so you can make the harness exit with any status.
- `CLAUDE_BOX_DEBUG=1` opts into the cage's state dump.

---

## Part 0 — Static checks (no docker)

```sh
bash -n claude-box && bash -n libcage.sh && bash -n entrypoint-cage.sh && echo "parse OK"
```

Exit-code mapping, in isolation (this is the authoritative check for the 127
bucket, which has no easy live trigger):

```sh
map() { local r="$1"; case "$r" in 125) r=126;; 126|127) r=127;; esac; echo "$r"; }
for c in 0 7 2 124 125 126 127 130 137; do printf 'docker=%s -> exit=%s\n' "$c" "$(map "$c")"; done
```
Expect: `0→0, 7→7, 2→2, 124→124, 125→126, 126→127, 127→127, 130→130, 137→137`.

fd-based flag selection, in isolation:

```sh
cat > /tmp/flag.sh <<'EOF'
f=(); [[ -t 0 || -p /dev/stdin || -f /dev/stdin || -S /dev/stdin ]] && f+=(-i)
[[ -t 1 && -t 2 ]] && f+=(-t); echo "flags=[${f[*]}]"
EOF
/tmp/flag.sh </dev/null   ; echo "  ^ no stdin  -> expect no -i"
echo x | /tmp/flag.sh     ; echo "  ^ pipe stdin-> expect -i"
/tmp/flag.sh </dev/null >/tmp/o 2>/dev/null; sed 's/^/redir stdout: /' /tmp/o; echo "  ^ expect no -t"
```

---

## Part 1 — Exit status propagates (was always 0)

```sh
cd /tmp/cbtest

# harness success
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'exit 0'  ; echo "exit=$?  (expect 0)"

# harness non-zero, verbatim (1–124) — the headline regression
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'exit 7'  ; echo "exit=$?  (expect 7)"
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'exit 42' ; echo "exit=$?  (expect 42)"

# signal death, verbatim (128+)
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'kill -INT $$'  ; echo "exit=$?  (expect 130)"
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'kill -TERM $$' ; echo "exit=$?  (expect 143)"
```

PASS: each `exit=` matches, and **no** `claude-box: fault=` line is printed for
these (they're harness statuses, not launcher faults).

---

## Part 2 — Launcher faults: distinct codes + machine-readable stderr

### 2a. Image missing → 125

Break the build in a throwaway copy of the repo so the real one is untouched
(`REPO` = your claude-box checkout):

```sh
REPO=~/src/claude-box            # adjust
cp -r "$REPO" /tmp/cb-broken
printf '\nRUN exit 1\n' >> /tmp/cb-broken/Dockerfile.claude
docker rmi -f claude-box >/dev/null 2>&1 || true

cd /tmp/cbtest
/tmp/cb-broken/claude-box -- --version 2>err.txt; echo "exit=$?  (expect 125)"
grep 'fault=image-missing' err.txt && echo "FAULT LINE OK"

rm -rf /tmp/cb-broken            # cleanup; next real run rebuilds the good image
```

PASS: `exit=125` and stderr carries `claude-box: fault=image-missing detail="…"`.

### 2b. Engine start failed → 126

Pre-run check (host without sysbox — most dev machines):

```sh
cd /tmp/cbtest
claude-box --engine sysbox -- --version 2>err.txt; echo "exit=$?  (expect 126)"
grep 'fault=engine-start-failed' err.txt && echo "FAULT LINE OK"
```

Runtime create failure (works on any host — a mount docker rejects at create,
exercising the docker-125 → 126 remap):

```sh
cd /tmp/cbtest
echo 'CLAUDE_BOX_EXTRA_MOUNTS=("/tmp:/tmp:bogusmode")' > .env.claude-box
claude-box -- --version 2>err.txt; echo "exit=$?  (expect 126)"
grep 'fault=engine-start-failed' err.txt && echo "FAULT LINE OK"
rm -f .env.claude-box
```

PASS: `exit=126` and a `fault=engine-start-failed` line in both.

### 2c. Harness not executable → 127

Authoritative check is Part 0's mapping (`docker 126/127 → 127`); docker only
returns 126/127 when it can't exec the *image entrypoint* (a corrupt image),
which has no convenient live trigger. Best-effort live probe (code may vary by
gosu build):

```sh
cd /tmp/cbtest
CLAUDE_BOX_EXEC=1 claude-box -- /no/such/binary 2>err.txt; echo "exit=$?"
grep 'fault=harness-not-executable' err.txt && echo "FAULT LINE OK (if 127)"
```

### 2d. Fault line survives a fully-headless run (no fd is a terminal)

```sh
cd /tmp/cbtest
claude-box --engine sysbox -- --version </dev/null >/dev/null 2>err.txt
echo "exit=$?  (expect 126)"
cat err.txt
grep -q 'fault=engine-start-failed' err.txt && echo "FAULT REACHED CAPTURED STDERR"
```

PASS: the fault line is in `err.txt` even though stderr is a file, not a tty —
the tty-gated `log()` would have dropped it; `fault()` does not.

---

## Part 3 — Streams & TTY

### 3a. Redirected stdout is clean: no CRLF, no `[cage]`, nothing from stderr

Run from an **interactive terminal** (stdout → file, stderr → terminal):

```sh
cd /tmp/cbtest
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'printf "hello\n"' > out.txt

od -c out.txt | head -1                       # expect: h e l l o \n   (no \r)
printf 'CR count:        '; grep -c $'\r' out.txt          # expect 0
printf 'cage log lines:  '; grep -c '\[cage\]' out.txt   # expect 0
printf 'line count:      '; wc -l < out.txt   # expect 1
```

Real-harness variant (needs auth):

```sh
claude-box -p 'reply with exactly: hello' > out2.txt
grep -c $'\r' out2.txt ; grep -c '\[cage\]' out2.txt   # both 0
```

PASS: `out.txt` is exactly `hello\n`; no `\r`, no `[cage]` lines, no stderr
content leaked into the file.

### 3b. `-i` only when stdin is connected

Piped stdin is forwarded (proves `-i` on for a pipe):

```sh
printf 'PING\n' | CLAUDE_BOX_EXEC=1 claude-box -- cat     # expect: PING
```

No-stdin interactive run does not hang (proves `-i` dropped for `/dev/null`):

```sh
cd /tmp/cbtest
timeout 45 claude-box </dev/null >/dev/null 2>&1; echo "exit=$?"
```

PASS: the pipe case prints `PING`; the no-stdin case returns **before** 45s
(exit is *not* 124 — it resolves instead of hanging on an attached-but-empty
stdin). The exact non-124 code depends on how Claude handles no prompt.

### 3c. Debug dump is opt-in

```sh
cd /tmp/cbtest
CLAUDE_BOX_EXEC=1 claude-box -- true </dev/null 2>off.txt
CLAUDE_BOX_DEBUG=1 CLAUDE_BOX_EXEC=1 claude-box -- true </dev/null 2>on.txt

printf 'default dump lines: '; grep -c 'state mount' off.txt   # expect 0
printf 'debug dump lines:   '; grep -c 'state mount' on.txt    # expect >=1
```

PASS: no dump by default; the `[cage] state mount (…)` listing appears only under
`CLAUDE_BOX_DEBUG=1`. The cage dump lists the state mount and, unlike the old
monolith, never cats credential file contents.

---

## Part 4 — SIGINT to a headless launcher never copies out from a live container

Start a long-running headless harness, signal the **launcher**, and confirm the
container was torn down (so any copy-out ran against a stopped container):

```sh
cd /tmp/cbtest
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'sleep 60' </dev/null >/dev/null 2>sig.err &
launcher=$!
sleep 10                                    # let the container come up
docker ps --filter 'name=claude-box-' --format '{{.Names}} {{.Status}}'   # should show it Up
kill -INT "$launcher"
wait "$launcher"; echo "launcher exit=$?"

# Assertions after the launcher has exited:
docker ps    --filter 'name=claude-box-' --format '{{.Names}}'   # expect: (empty) — not running
docker ps -a --filter 'name=claude-box-' --format '{{.Names}}'   # expect: (empty) — --rm cleaned up
```

PASS: after the SIGINT the launcher exits promptly and **no** `claude-box-…`
container is left running or lingering. sync_back's guard stops the container
before touching the state volume, so the copy-out cannot race a live container.

---

## Part 5 — Warnings survive a non-terminal stderr

Launcher warnings must reach captured stderr headless, identically to an
interactive run. Prime the userns-strategy cache to `unsupported` so the
rootless engine prints its warning block, then capture with stderr redirected
(not a tty):

```sh
# The cache key is the docker-host slug; prime whichever files exist (there is
# one per host you've probed):
for f in ~/.claude-box/.userns-strategy-*; do echo unsupported > "$f"; done

claude-box --engine rootless -- --version >out.txt 2>err.txt || true
grep -q '^\[claude-box\] WARNING: this docker host cannot' err.txt && echo "WARN_HEADLESS_OK"

# Restore real probing afterwards:
rm -f ~/.claude-box/.userns-strategy-*
```

PASS: `WARN_HEADLESS_OK`. The same `[claude-box] WARNING: …` line appears on an
interactive run's terminal, because `warn()` ignores the tty.

---

## Part 6 — Address a box started headless

A caller starts a box with no tty, discovers its container name via
`--name-file`, and stops it. Uses the `CLAUDE_BOX_EXEC` hook to hold the box
open with a plain `sleep` (no auth needed):

```sh
h="$(mktemp)"
CLAUDE_BOX_EXEC=1 claude-box --name-file "$h" -- sleep 300 >/dev/null 2>&1 &
launcher=$!

# The name is published just before the container starts; poll for it.
for _ in $(seq 1 100); do [ -s "$h" ] && break; sleep 0.1; done
name="$(cat "$h")"; echo "handle=$name"

docker exec "$name" true && echo "EXEC_OK"
docker stop "$name" >/dev/null && echo "STOP_OK"
wait "$launcher" 2>/dev/null

[ -e "$h" ] || echo "NAME_FILE_CLEANED"
```

PASS: `handle=…`, `EXEC_OK`, `STOP_OK`, `NAME_FILE_CLEANED`. A caller-supplied
`--name my-box` is addressable the same way; an invalid `--name 'a b/c'` exits 1
with `[claude-box] --name: invalid container name` and starts nothing.

---

## Results checklist

| # | Criterion | Expected |
|---|---|---|
| 1 | harness success | exit 0, no fault line | PASS
| 1 | harness non-zero (was always 0) | exit 7 / 42, no fault line | PASS
| 1 | signal death | exit 130 / 143 | PASS
| 2a | image missing | exit 125 + `fault=image-missing` |
| 2b | engine start failed | exit 126 + `fault=engine-start-failed` | PASS
| 2c | harness not executable | mapping check `126/127→127`; live `fault=harness-not-executable` |
| 2d | fault line, fully headless | line present in captured stderr |
| 3a | redirected stdout | no `\r`, no `[cage]`, no stderr leak |
| 3b | `-i` gating | pipe round-trips; no-stdin run doesn't hang (≠124) |
| 3c | debug dump | absent by default; present with `CLAUDE_BOX_DEBUG=1` |
| 4 | SIGINT headless | launcher exits; no live/lingering container |
| 5 | warnings survive headless | `[claude-box] WARNING: …` in captured stderr |
| 6 | address a headless box | `--name-file` published, `docker stop` works, file cleaned |
| 6 | `--name` validation | bad name exits 1, starts nothing |
