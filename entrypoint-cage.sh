#!/bin/bash
# cage-entrypoint — the payload-free entrypoint shared by every box.
#
# Creates a passwd/group entry for the host UID (interactive harnesses such as
# Claude Code and Codex silently exit when getpwuid() returns nothing), starts
# the bounded nested engine, wires the ssh relays, then execs whatever command
# the launcher handed it as the host user. The command IS the payload (e.g.
# `claude --dangerously-skip-permissions …` or
# `codex --dangerously-bypass-approvals-and-sandbox …`); this file knows nothing
# about which harness it is.
#
# Env contract (all set by libcage.sh):
#   HOST_UID / HOST_GID / HOME   the host user to become
#   CAGE_STATE_MOUNT             the payload's state dir inside the box, chowned
#                                to the host user (e.g. ~/.claude, ~/.codex)
#   CAGE_ENGINE                  rootless | rootful | none
#   CAGE_SSH_RELAY_PORT          colima TCP->unix ssh-agent relay port (optional)
#   CAGE_DEBUG                   opt-in state dump (optional)

set -e

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
HOST_HOME="${HOME:-/home/hostuser}"
USERNAME="hostuser"

# Put the user's local bin on PATH. The payload is exec'd directly (no login
# shell sources a profile), so child processes inherit PATH from this env.
export PATH="${HOST_HOME}/.local/bin:${PATH}"

# Neutral host->box file relay. The launcher stages host files under a
# cage-owned .cage-relay/ inside the state mount (payload-independent: the name
# is the cage's, not any harness's config file), so the relay rides the same
# state volume the colima flush already carries. Copy them to the paths the tools
# expect. Clean up a stale dir if Docker created one at a target.
_RELAY="${CAGE_STATE_MOUNT:-${HOME}/.cage}/.cage-relay"
if [ -f "${_RELAY}/gitconfig" ]; then
  [ -d "${HOME}/.gitconfig" ] && rm -rf "${HOME}/.gitconfig"
  cp -f "${_RELAY}/gitconfig" "${HOME}/.gitconfig" 2>/dev/null || true
fi
if [ -s "${_RELAY}/AGENTS.md" ]; then
  [ -d "${HOME}/.agents/AGENTS.md" ] && rm -rf "${HOME}/.agents/AGENTS.md"
  mkdir -p "${HOME}/.agents"
  cp -f "${_RELAY}/AGENTS.md" "${HOME}/.agents/AGENTS.md" 2>/dev/null || true
fi

echo "[cage] starting..." >&2
if [ "$(id -u)" = "0" ] && [ "${HOST_UID}" != "0" ]; then
  echo "[cage] creating user UID=${HOST_UID} GID=${HOST_GID}..." >&2
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
  # failure (|| true): when a box is launched from ${HOME} itself the wrapper
  # bind-mounts PROJECT_DIR (== ${HOME}) into the container, so ${HOME} is a
  # virtiofs mount root and chowning it returns EPERM, which under `set -e` would
  # abort the entrypoint and kill the container. Skipping it is safe: a virtiofs
  # home already maps to the host UID.
  mkdir -p "${HOST_HOME}"
  chown "${HOST_UID}:${HOST_GID}" "${HOST_HOME}" 2>/dev/null || true

  # Fix ownership on the payload's state tree. The init-container flush and
  # Docker-created mount points leave root-owned entries that cause EACCES when
  # the harness tries to write sessions, config, etc.
  if [ -n "${CAGE_STATE_MOUNT:-}" ]; then
    [ -d "${CAGE_STATE_MOUNT}" ] && chown -R "${HOST_UID}:${HOST_GID}" "${CAGE_STATE_MOUNT}" 2>/dev/null || true
  fi

  # Payload-specific prep, if the payload image shipped a hook. Runs as root,
  # before the engine starts, with the same env this script sees. cage-base
  # ships none; claude-box drops a theme install + stale-dir cleanup here.
  if [ -x /usr/local/share/cage/payload-init ]; then
    /usr/local/share/cage/payload-init || true
  fi

  # ---- Nested container engine (ADR-0041 decision 3) ----
  # A mounted host socket is never acceptable: it is root-equivalent control of
  # the host, so the cage would not be host-isolated at all. Any socket present
  # this early can only have been mounted in from outside — refuse to start.
  if [ -S /var/run/docker.sock ]; then
    echo "[cage] FATAL: /var/run/docker.sock is mounted from the host." >&2
    echo "[cage] ADR-0041 (decision 3): a mounted host docker socket voids the cage's" >&2
    echo "[cage] host isolation. Remove the mount (check *_EXTRA_MOUNTS)." >&2
    exit 1
  fi

  # CAGE_ENGINE is set by the launcher: rootless (default), rootful (sysbox or
  # privileged dind — identical in here), or none. The engine's data root must
  # NOT be the container's overlayfs (overlay-on-overlay is rejected), so the
  # launcher mounts an anonymous volume at the data-root path.
  ENGINE="${CAGE_ENGINE:-none}"
  ENGINE_LOG="/tmp/cage-engine.log"
  case "$ENGINE" in
    rootless)
      grep -q "^${USERNAME}:" /etc/subuid 2>/dev/null || echo "${USERNAME}:100000:65536" >> /etc/subuid
      grep -q "^${USERNAME}:" /etc/subgid 2>/dev/null || echo "${USERNAME}:100000:65536" >> /etc/subgid
      export XDG_RUNTIME_DIR="/run/user/${HOST_UID}"
      mkdir -p "$XDG_RUNTIME_DIR" /var/lib/claude-box-engine
      chown "${HOST_UID}:${HOST_GID}" "$XDG_RUNTIME_DIR" /var/lib/claude-box-engine
      chmod 700 "$XDG_RUNTIME_DIR"
      echo "[cage] starting rootless nested engine..." >&2
      gosu "${USERNAME}" env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" HOME="${HOST_HOME}" PATH="${PATH}" \
        DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns \
        DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=builtin \
        dockerd-rootless.sh --data-root /var/lib/claude-box-engine \
        >"$ENGINE_LOG" 2>&1 &
      export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
      ;;
    rootful)
      echo "[cage] starting rootful nested engine..." >&2
      dockerd >"$ENGINE_LOG" 2>&1 &
      usermod -aG docker "${USERNAME}" 2>/dev/null || true
      export DOCKER_HOST="unix:///var/run/docker.sock"
      ;;
    *)
      ;;
  esac

  # Block until the engine answers (bounded): the first thing a session does may
  # be a docker command, and racing the daemon start loses. On failure, warn
  # loudly and continue WITHOUT an engine — never fall back to any other socket.
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
      echo "[cage] nested engine ready (${ENGINE}) at ${DOCKER_HOST}" >&2
    else
      echo "[cage] WARNING: nested engine (${ENGINE}) not ready after 20s — continuing without one." >&2
      echo "[cage] engine log tail (${ENGINE_LOG}):" >&2
      tail -n 20 "$ENGINE_LOG" >&2 2>/dev/null || true
      unset DOCKER_HOST
    fi
  fi

  # Docker Desktop forwards the host ssh-agent at /run/host-services/ssh-auth.sock
  # but the socket inside the container is root-owned. Chown it to the host user
  # so signing/git-over-ssh works without escalation. Silently ignore if absent.
  if [ -S /run/host-services/ssh-auth.sock ]; then
    chown "${HOST_UID}:${HOST_GID}" /run/host-services/ssh-auth.sock || true
  fi

  # Colima TCP->Unix socket relay. The host-side Python relay exposes the SSH
  # agent on a TCP port; socat converts it back to a Unix socket inside the
  # container so SSH_AUTH_SOCK works normally.
  if [ -n "${CAGE_SSH_RELAY_PORT:-}" ]; then
    echo "[cage] wiring ssh relay..." >&2
    CONTAINER_SSH_SOCK="/tmp/ssh-agent.sock"
    rm -f "$CONTAINER_SSH_SOCK"
    gosu "${USERNAME}" socat \
      UNIX-LISTEN:"${CONTAINER_SSH_SOCK}",fork,mode=600 \
      TCP:host.docker.internal:"${CAGE_SSH_RELAY_PORT}" &
    export SSH_AUTH_SOCK="$CONTAINER_SSH_SOCK"
    sleep 0.2
  fi

  # State dump is opt-in (CAGE_DEBUG), on stderr. Generic: lists the state mount.
  if [ -n "${CAGE_DEBUG:-}" ]; then
    echo "[cage] HOME=${HOME}" >&2
    echo "[cage] state mount (${CAGE_STATE_MOUNT:-<unset>}):" >&2
    ls -la "${CAGE_STATE_MOUNT}" >&2 2>/dev/null || echo "(missing)" >&2
    echo >&2
  fi

  # gosu does a direct exec as the user — no shell wrapper, proper TTY + signal
  # inheritance for an interactive UI. "$@" is the payload command the launcher
  # supplied; the cage never names a harness of its own.
  echo "[cage] exec: $*" >&2
  exec gosu "${USERNAME}" "$@"
fi

# Already running as the right user (or root was requested).
exec "$@"
