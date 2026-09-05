# Runbook: cage / payload acceptance

Proves the extraction: the cage (`libcage.sh` + `Dockerfile.cage` +
`entrypoint-cage.sh`) owns host isolation and the nested engine exactly once,
carries no agent harness, and runs an arbitrary payload. Four payloads,
`claude-box`, `codex-box`, `deepseek-box`, and `pi-box`, compose that one cage
without duplicating it.

Maps to the ticket's acceptance:

- the engine block exists exactly once (Part 0)
- the cage base image has no harness baked in (Part 1)
- each payload composes the cage and adds only its own harness (Part 1)
- the bounded nested engine runs inside the box, host socket never mounted (Part 2, 3)
- the generic exec / exit-status contract holds through the cage, per payload (Part 4)

## Prerequisites

- A **real docker host** (Docker Desktop / OrbStack / Colima / rootless). Run
  these on the host, not inside a box.
- `claude-box`, `codex-box`, `deepseek-box`, and `pi-box` from this branch on
  `PATH`.
- A throwaway project dir that is **not** `$HOME` (the launcher refuses `$HOME`
  and its ancestors):
  ```sh
  mkdir -p /tmp/cbtest && cd /tmp/cbtest && git init -q
  ```
- The **first run of each box builds images**: `cage-base` first, then the
  payload image `FROM cage-base`. Warm all four once and ignore their output:
  ```sh
  CLAUDE_BOX_EXEC=1 claude-box -- true >/dev/null 2>&1 || true
  CODEX_BOX_EXEC=1  codex-box  -- true >/dev/null 2>&1 || true
  DEEPSEEK_BOX_EXEC=1 deepseek-box -- true >/dev/null 2>&1 || true
  PI_BOX_EXEC=1 pi-box -- true >/dev/null 2>&1 || true
  ```
- No harness auth is needed anywhere in this runbook: every in-box command uses
  the generic exec hook (`CLAUDE_BOX_EXEC`, `CODEX_BOX_EXEC`,
  `DEEPSEEK_BOX_EXEC`, or `PI_BOX_EXEC`), which replaces the harness with a bare
  command run as the host user inside the cage.

The exec hook is the seam under test. For example,
`PI_BOX_EXEC=1 pi-box -- <cmd…>` runs `<cmd…>` as the in-box command instead of
the harness, so a check can inspect the cage from the inside. The other variants
use their corresponding `*_BOX_EXEC` variables.

---

## Part 0: The engine block exists once (static, no docker)

The cage's security posture and nested-engine assembly live in exactly one file.
No payload wrapper rebuilds them.

```sh
# The ENGINE case and engine_args construction are only in libcage.sh:
grep -rln 'engine_args+=(' .            # expect: ./libcage.sh   (one line, nothing else)

# The payload wrappers source the cage; they do not re-implement it:
grep -n 'source .*libcage.sh' claude-box codex-box deepseek-box pi-box
# expect: one match each

# Parse-check the whole set:
for f in claude-box codex-box deepseek-box deepseek-web-proxy.sh pi-box \
         libcage.sh entrypoint-cage.sh userns-probe.sh payload-init-claude.sh; do
  bash -n "$f" && echo "parse OK: $f"
done
```

PASS: `engine_args+=(` appears only in `libcage.sh`; all wrappers source it;
every script parses.

---

## Part 1: The cage base carries no harness; each payload adds its own

The base image is payload-free. Each payload image is `FROM cage-base` and adds
exactly one harness.

```sh
# Payloads compose the cage base:
grep -H '^FROM' Dockerfile.claude Dockerfile.codex Dockerfile.deepseek Dockerfile.pi
# expect: Dockerfile.claude:FROM cage-base
#         Dockerfile.codex:FROM cage-base
#         Dockerfile.deepseek:FROM cage-base
#         Dockerfile.pi:FROM cage-base

# cage-base has NO agent harness on PATH:
docker run --rm --entrypoint sh cage-base -c \
  'command -v claude; command -v codex; command -v dsh; command -v pi; echo "exit=$?"'
# expect: no path printed for any harness; the final `command -v` returns non-zero

# cage-base DOES carry the shared tooling (the cage's job):
docker run --rm --entrypoint sh cage-base -c \
  'for b in git gh docker dockerd-rootless.sh gosu uv; do command -v "$b" >/dev/null \
   && echo "have $b" || echo "MISSING $b"; done'
# expect: have git / gh / docker / dockerd-rootless.sh / gosu / uv

# Each payload adds only its own harness on top of the same base:
docker run --rm --entrypoint sh claude-box -c 'command -v claude && ! command -v codex && ! command -v dsh && ! command -v pi && echo CLAUDE_ONLY'
docker run --rm --entrypoint sh codex-box -c 'command -v codex && ! command -v claude && ! command -v dsh && ! command -v pi && echo CODEX_ONLY'
docker run --rm --entrypoint sh deepseek-box -c 'command -v dsh && ! command -v claude && ! command -v codex && ! command -v pi && echo DEEPSEEK_ONLY'
docker run --rm --entrypoint sh pi-box -c 'command -v pi && ! command -v claude && ! command -v codex && ! command -v dsh && echo PI_ONLY'
```

PASS: `cage-base` resolves none of `claude`, `codex`, `dsh`, or `pi` but carries
the shared tooling; each payload image resolves only its own harness.

---

## Part 2: The bounded nested engine runs inside the box

The four checks the README promises, run inside each box via the exec hook. The
default posture (`--engine auto`) resolves to `sysbox` if the host offers the
`sysbox-runc` runtime, else `rootless`. These expectations are for the
**rootless** default (the typical Docker Desktop / OrbStack case); the sysbox /
rootful notes follow each check.

```sh
cd /tmp/cbtest

# 1. The nested daemon reports itself, and (rootless) advertises name=rootless:
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'docker info --format "{{.SecurityOptions}}"'
#   rootless  -> contains  name=rootless
#   sysbox / privileged-dind -> rootful daemon; name=rootless absent (expected)

# 2. No host socket leaked in. Under rootless the daemon's own socket lives under
#    XDG_RUNTIME_DIR, and /var/run/docker.sock is absent:
CLAUDE_BOX_EXEC=1 claude-box -- bash -c '
  test ! -S /var/run/docker.sock && echo "no /var/run/docker.sock (rootless OK)"
  echo "DOCKER_HOST=$DOCKER_HOST"'
#   rootless -> "no /var/run/docker.sock", DOCKER_HOST under /run/user/<uid>/
#   rootful  -> /var/run/docker.sock present but owned by the NESTED daemon,
#               created in-box (never a host mount)

# 3. The nested engine is real: it pulls and runs a container end to end:
CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'docker run --rm hello-world' | grep -q 'Hello from Docker' \
  && echo "NESTED ENGINE RUNS CONTAINERS"

# 4. The same holds for the codex payload (same cage, same engine):
CODEX_BOX_EXEC=1 codex-box -- bash -c 'docker info --format "{{.SecurityOptions}}"'

# 5. And for the DeepSeek Harness payload:
DEEPSEEK_BOX_EXEC=1 deepseek-box -- bash -c 'docker info --format "{{.SecurityOptions}}"'

# 6. And for the Pi payload:
PI_BOX_EXEC=1 pi-box -- bash -c 'docker info --format "{{.SecurityOptions}}"'
```

PASS: `docker info` answers inside all four boxes; under the rootless default it
contains `name=rootless` and `/var/run/docker.sock` is absent; `hello-world`
runs to completion. Under `--engine sysbox` or `--engine privileged-dind` the
daemon is rootful (no `name=rootless`) and `/var/run/docker.sock` is the nested
daemon's own, created in-box.

To force a specific posture: `--engine rootless|sysbox|privileged-dind|none`.
With `--engine none` every `docker …` inside the box fails to connect; that is
the expected result, not a fault.

---

## Part 3: A mounted host socket is refused (all payloads)

The cage voids its own isolation if a host docker socket is present, so the
entrypoint refuses to start when one is mounted. This is the cage's guarantee,
so it must hold for every payload.

Mount your host's real socket at the in-box path `/var/run/docker.sock`. Use
whichever host socket exists:

```sh
cd /tmp/cbtest
# Docker Desktop / rootful host:
SOCK=/var/run/docker.sock
# Rootless host: SOCK="${XDG_RUNTIME_DIR}/docker.sock"  (e.g. /run/user/$(id -u)/docker.sock)

CLAUDE_BOX_EXTRA_MOUNTS=("${SOCK}:/var/run/docker.sock") \
  CLAUDE_BOX_EXEC=1 claude-box -- true 2>err.txt; echo "exit=$?"
grep -q 'FATAL: /var/run/docker.sock is mounted from the host' err.txt && echo "CLAUDE REFUSED"

CODEX_BOX_EXTRA_MOUNTS=("${SOCK}:/var/run/docker.sock") \
  CODEX_BOX_EXEC=1 codex-box -- true 2>err.txt; echo "exit=$?"
grep -q 'FATAL: /var/run/docker.sock is mounted from the host' err.txt && echo "CODEX REFUSED"

DEEPSEEK_BOX_EXTRA_MOUNTS=("${SOCK}:/var/run/docker.sock") \
  DEEPSEEK_BOX_EXEC=1 deepseek-box -- true 2>err.txt; echo "exit=$?"
grep -q 'FATAL: /var/run/docker.sock is mounted from the host' err.txt && echo "DEEPSEEK REFUSED"

PI_BOX_EXTRA_MOUNTS=("${SOCK}:/var/run/docker.sock") \
  PI_BOX_EXEC=1 pi-box -- true 2>err.txt; echo "exit=$?"
grep -q 'FATAL: /var/run/docker.sock is mounted from the host' err.txt && echo "PI REFUSED"
```

PASS: all boxes print the `FATAL: /var/run/docker.sock is mounted from the host`
refusal and exit non-zero without ever reaching the harness. The refusal lives in
`entrypoint-cage.sh` (shared), so adding another payload inherits it for free.

---

## Part 4: The generic exec / exit-status contract holds per payload

The exit-status contract is the cage's, exercised through each wrapper. The
harness's status propagates verbatim; a launcher fault maps to its own code. (The
exhaustive exit-mapping matrix is in
[runbook-headless-exit.md](runbook-headless-exit.md); here we only confirm the
seam is wired identically for every payload.)

```sh
cd /tmp/cbtest

for box in "claude-box:CLAUDE_BOX_EXEC" "codex-box:CODEX_BOX_EXEC" \
           "deepseek-box:DEEPSEEK_BOX_EXEC" "pi-box:PI_BOX_EXEC"; do
  name="${box%%:*}"; var="${box##*:}"
  env "$var=1" "$name" -- bash -c 'exit 0'   ; echo "$name success -> $?  (expect 0)"
  env "$var=1" "$name" -- bash -c 'exit 7'   ; echo "$name status  -> $?  (expect 7)"
  env "$var=1" "$name" -- bash -c 'kill -INT $$'; echo "$name signal -> $?  (expect 130)"
done

# The passthrough round-trips stdin (proves -i gating) for all four:
printf 'PING\n' | CLAUDE_BOX_EXEC=1 claude-box -- cat   # expect: PING
printf 'PING\n' | CODEX_BOX_EXEC=1  codex-box  -- cat   # expect: PING
printf 'PING\n' | DEEPSEEK_BOX_EXEC=1 deepseek-box -- cat # expect: PING
printf 'PING\n' | PI_BOX_EXEC=1       pi-box       -- cat # expect: PING
```

PASS: each box returns `0`, `7`, `130` verbatim with no `fault=` line (these are
harness statuses, not launcher faults), and round-trips the pipe. Identical
behaviour across all payloads confirms the contract lives in the cage, not the
wrapper.

---

## Results checklist

| # | Criterion | Expected |
|---|---|---|
| 0 | engine block exists once | `engine_args+=(` only in `libcage.sh`; all wrappers source it |
| 1 | cage base is harness-free | `cage-base` resolves none of `claude`, `codex`, `dsh`, or `pi` |
| 1 | cage base carries shared tooling | `git`/`gh`/`docker`/`dockerd-rootless.sh`/`gosu`/`uv` present |
| 1 | payloads compose the cage | each is `FROM cage-base`; adds only its own harness |
| 2 | nested engine reports itself | `docker info` answers in all boxes |
| 2 | rootless posture | `SecurityOptions` contains `name=rootless`; no `/var/run/docker.sock` |
| 2 | nested engine runs containers | `hello-world` completes in-box |
| 3 | host socket refused | all boxes print the FATAL refusal, exit non-zero, never reach the harness |
| 4 | exit status per payload | `0` / `7` / `130` verbatim, no `fault=` line, all payloads |
| 4 | stdin round-trip per payload | `PING` echoes back for all payloads |
