#!/bin/bash
# Entrypoint for claude-box.
# Creates a passwd/group entry for the host UID so Claude Code can resolve
# the user (it silently exits when getpwuid() returns nothing).
# Must run as root first; drops to the host user immediately after.

set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
HOST_HOME="${HOME:-/home/hostuser}"
USERNAME="hostuser"

# Put the user's local bin on PATH. claude is exec'd directly (no login shell
# sources a profile), so child processes inherit PATH from this env. Covers
# pip/uv --user installs and anything else dropped in ~/.local/bin.
export PATH="${HOST_HOME}/.local/bin:${PATH}"

# Clean up stale directories that Docker auto-creates when a bind-mount source
# doesn't exist. On Colima this is common because virtiofs cache delays can make
# freshly-written host files invisible to the VM at mount time. These root-owned
# directories persist in the state volume and shadow the real files on subsequent
# runs, so we remove them unconditionally at startup.
# Only clean paths inside the state volume (${HOME}/.claude/). Paths like
# ${HOME}/.claude.json are separate bind mounts and can't be removed.
for _stale in "${HOME}/.claude/CLAUDE.md" "${HOME}/.claude/.credentials.json" \
              "${HOME}/.claude/.claude.json" "${HOME}/.claude/settings.json"; do
  [ -d "$_stale" ] && rm -rf "$_stale"
done

# Install the baked-in claude-box theme so the container is visually distinct.
mkdir -p "${HOME}/.claude/themes"
cp -f /usr/local/share/claude-box-theme.json "${HOME}/.claude/themes/claude-box.json" 2>/dev/null || true

# If .gitconfig was synced into the state dir (Colima), copy it to $HOME.
# Also clean up stale directory if Docker created one at $HOME/.gitconfig.
[ -d "${HOME}/.gitconfig" ] && rm -rf "${HOME}/.gitconfig"
[ -f "${HOME}/.claude/.gitconfig" ] && cp -f "${HOME}/.claude/.gitconfig" "${HOME}/.gitconfig" 2>/dev/null || true

# claude-box concatenates all AGENTS.md files (global + parents + project) into
# the state dir; copy the merged result out to the ~/.agents/AGENTS.md path the
# global CLAUDE.md tells Claude to read. Clean up a stale dir if Docker created
# one at the file's target.
[ -d "${HOME}/.agents/AGENTS.md" ] && rm -rf "${HOME}/.agents/AGENTS.md"
if [ -s "${HOME}/.claude/.agents/AGENTS.md" ]; then
  mkdir -p "${HOME}/.agents"
  cp -f "${HOME}/.claude/.agents/AGENTS.md" "${HOME}/.agents/AGENTS.md" 2>/dev/null || true
fi

echo "[entrypoint] starting..." >&2
if [ "$(id -u)" = "0" ] && [ "${HOST_UID}" != "0" ]; then
  echo "[entrypoint] creating user UID=${HOST_UID} GID=${HOST_GID}..." >&2
  # Create group if it doesn't already exist
  if ! getent group "${HOST_GID}" >/dev/null 2>&1; then
    groupadd -g "${HOST_GID}" "${USERNAME}"
  fi

  # Create user if it doesn't already exist.
  # --non-unique allows UIDs outside the distro's 1000-60000 range (e.g. macOS UID 501).
  if ! getent passwd "${HOST_UID}" >/dev/null 2>&1; then
    useradd --non-unique -u "${HOST_UID}" -g "${HOST_GID}" -d "${HOST_HOME}" -s /bin/bash -M "${USERNAME}" 2>/dev/null
  fi

  # Ensure home dir exists and is owned by the host user. Tolerate a chown
  # failure (|| true): when claude-box is launched from ${HOME} itself, the
  # wrapper bind-mounts PROJECT_DIR (== ${HOME}) into the container, so ${HOME}
  # is a virtiofs mount root rather than a plain container-local dir — and
  # chowning a virtiofs mount root returns EPERM, which under `set -e` aborts
  # the entrypoint and kills the container before claude ever starts. The
  # .claude and ssh-socket chowns below already tolerate this; the home chown
  # must too. Skipping it is safe: a virtiofs home already maps to the host UID,
  # and the per-path .claude chown below still fixes the dirs claude writes to.
  mkdir -p "${HOST_HOME}"
  chown "${HOST_UID}:${HOST_GID}" "${HOST_HOME}" 2>/dev/null || true

  # Fix ownership on the entire .claude tree. The init container flush and
  # Docker-created mount points leave root-owned entries that cause EACCES
  # when Claude Code tries to write sessions, shell env, etc.
  chown -R "${HOST_UID}:${HOST_GID}" "${HOME}/.claude" 2>/dev/null || true

  # ---- Nested container engine (ADR-0041 decision 3) ----
  # The cage runs its OWN engine, bounded by the cage. A mounted host socket is
  # never acceptable: it is root-equivalent control of the host (any process
  # could start a privileged container and mount the host fs), so the cage
  # would not be host-isolated at all. Any socket present this early can only
  # have been mounted in from outside — refuse to start.
  if [ -S /var/run/docker.sock ]; then
    echo "[entrypoint] FATAL: /var/run/docker.sock is mounted from the host." >&2
    echo "[entrypoint] ADR-0041 (decision 3): a mounted host docker socket voids the cage's" >&2
    echo "[entrypoint] host isolation. Remove the mount (check CLAUDE_BOX_EXTRA_MOUNTS)." >&2
    exit 1
  fi

  # CLAUDE_BOX_ENGINE is set by the launcher: rootless (default), rootful
  # (sysbox or privileged dind — identical in here), or none. The engine's
  # data root must NOT be the container's overlayfs (overlay-on-overlay is
  # rejected by the kernel), so the launcher mounts an anonymous volume at
  # the data-root path for the posture it selected.
  ENGINE="${CLAUDE_BOX_ENGINE:-none}"
  ENGINE_LOG="/tmp/claude-box-engine.log"
  case "$ENGINE" in
    rootless)
      # dockerd-rootless (rootlesskit) as the unprivileged host user: the
      # daemon holds no capabilities in the cage's user namespace, only in
      # the nested one it creates — authority bounded by the cage. Needs
      # subuid/subgid ranges for the userns and a private runtime dir.
      grep -q "^${USERNAME}:" /etc/subuid 2>/dev/null || echo "${USERNAME}:100000:65536" >> /etc/subuid
      grep -q "^${USERNAME}:" /etc/subgid 2>/dev/null || echo "${USERNAME}:100000:65536" >> /etc/subgid
      export XDG_RUNTIME_DIR="/run/user/${HOST_UID}"
      mkdir -p "$XDG_RUNTIME_DIR" /var/lib/claude-box-engine
      chown "${HOST_UID}:${HOST_GID}" "$XDG_RUNTIME_DIR" /var/lib/claude-box-engine
      chmod 700 "$XDG_RUNTIME_DIR"
      echo "[entrypoint] starting rootless nested engine..." >&2
      gosu "${USERNAME}" env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" HOME="${HOST_HOME}" PATH="${PATH}" \
        DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns \
        DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=builtin \
        dockerd-rootless.sh --data-root /var/lib/claude-box-engine \
        >"$ENGINE_LOG" 2>&1 &
      export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
      ;;
    rootful)
      # Rootful dockerd inside the cage — reached via sysbox (engine bounded
      # by the sysbox runtime) or --privileged (ADR-0041's named weaker
      # posture). Default data root /var/lib/docker: sysbox provisions that
      # exact path itself, and the privileged posture gets an anonymous
      # volume there from the launcher. The socket it creates is the NESTED
      # daemon's, not the host's (a host socket was refused above). hostuser
      # reaches it via the docker group; gosu applies supplementary groups
      # at exec.
      echo "[entrypoint] starting rootful nested engine..." >&2
      dockerd >"$ENGINE_LOG" 2>&1 &
      usermod -aG docker "${USERNAME}" 2>/dev/null || true
      export DOCKER_HOST="unix:///var/run/docker.sock"
      ;;
    *)
      ;;
  esac

  # Block until the engine answers (bounded): the very first thing a session
  # does may be a docker command, and racing the daemon start loses. On
  # failure, warn loudly and continue WITHOUT an engine — never fall back to
  # any other socket; the ambient DOCKER_HOST is the single authority.
  if [ -n "${DOCKER_HOST:-}" ]; then
    _engine_ok=0
    for _i in $(seq 1 80); do
      if gosu "${USERNAME}" env DOCKER_HOST="${DOCKER_HOST}" docker version >/dev/null 2>&1; then
        _engine_ok=1
        break
      fi
      sleep 0.25
    done
    if [ "$_engine_ok" = 1 ]; then
      echo "[entrypoint] nested engine ready (${ENGINE}) at ${DOCKER_HOST}" >&2
    else
      echo "[entrypoint] WARNING: nested engine (${ENGINE}) not ready after 20s — continuing without one." >&2
      echo "[entrypoint] engine log tail (${ENGINE_LOG}):" >&2
      tail -n 20 "$ENGINE_LOG" >&2 2>/dev/null || true
      unset DOCKER_HOST
    fi
  fi

  # Docker Desktop forwards the host ssh-agent at /run/host-services/ssh-auth.sock
  # but the socket inside the container is root-owned. Chown it to the host user
  # so signing/git-over-ssh works without escalation. Silently ignore if absent
  # (Linux Docker / no agent forwarded / --no-ssh).
  if [ -S /run/host-services/ssh-auth.sock ]; then
    chown "${HOST_UID}:${HOST_GID}" /run/host-services/ssh-auth.sock || true
  fi

  # Colima TCP→Unix socket relay. The host-side Python relay exposes the SSH
  # agent on a TCP port; socat converts it back to a Unix socket inside the
  # container so SSH_AUTH_SOCK works normally for git signing and SSH auth.
  echo "[entrypoint] checking ssh relay..." >&2
  if [ -n "${CLAUDE_BOX_SSH_RELAY_PORT:-}" ]; then
    CONTAINER_SSH_SOCK="/tmp/ssh-agent.sock"
    rm -f "$CONTAINER_SSH_SOCK"
    gosu "${USERNAME}" socat \
      UNIX-LISTEN:"${CONTAINER_SSH_SOCK}",fork,mode=600 \
      TCP:host.docker.internal:"${CLAUDE_BOX_SSH_RELAY_PORT}" &
    export SSH_AUTH_SOCK="$CONTAINER_SSH_SOCK"
    sleep 0.2
  fi

  # gosu does a direct exec as the user — no shell wrapper, proper TTY + signal
  # inheritance for Claude Code's interactive UI.
  #
  # State dump is opt-in (CLAUDE_BOX_DEBUG=1), and stays on stderr. It's off by
  # default because it's noisy and mildly sensitive: it lists ~/.claude, reports
  # the credential file's byte count, and prints the first 200 bytes of
  # .claude.json — none of which a headless caller wants merged into its logs.
  if [ -n "${CLAUDE_BOX_DEBUG:-}" ]; then
    echo "[entrypoint] HOME=${HOME}" >&2
    echo "[entrypoint] .claude contents:" >&2
    ls -la "${HOME}/.claude/" >&2 2>/dev/null || echo "(missing)" >&2
    echo "[entrypoint] .credentials.json:" >&2
    if [ -f "${HOME}/.claude/.credentials.json" ]; then
      echo "present ($(wc -c < "${HOME}/.claude/.credentials.json") bytes)" >&2
    else
      echo "(missing)" >&2
    fi
    echo >&2
    echo "[entrypoint] .claude.json:" >&2
    head -c 200 "${HOME}/.claude.json" >&2 2>/dev/null || echo "(missing)" >&2
    echo >&2
  fi
  # Debug/acceptance hook: CLAUDE_BOX_EXEC=1 execs the args as a raw command
  # instead of claude — used to run docs/cage-engine-acceptance.md in-cage
  # non-interactively (e.g. `CLAUDE_BOX_EXEC=1 ... bash -c 'docker info'`).
  if [ -n "${CLAUDE_BOX_EXEC:-}" ]; then
    # The launcher always prepends claude's --dangerously-skip-permissions; drop
    # a single leading one so EXEC runs the bare command that follows (this is
    # what makes `CLAUDE_BOX_EXEC=1 claude-box -- bash -c 'exit 7'` exit 7,
    # exercising the launcher's exit-status propagation end to end).
    [ "${1:-}" = "--dangerously-skip-permissions" ] && shift
    echo "[entrypoint] exec (CLAUDE_BOX_EXEC): $*" >&2
    exec gosu "${USERNAME}" "$@"
  fi
  echo "[entrypoint] launching claude $*" >&2
  exec gosu "${USERNAME}" claude "$@"
fi

# Already running as the right user (or root was requested)
exec claude "$@"
