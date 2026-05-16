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

# Only needed when running as root with a real host UID to impersonate
# Clean up stale directories that Docker auto-creates when a bind-mount source
# doesn't exist (common on Colima where virtiofs cache delays make host files
# invisible to the VM).  Then write volatile content passed as base64 env vars.
for _stale in "${HOME}/.claude/CLAUDE.md" "${HOME}/.claude/.credentials.json" \
              "${HOME}/.claude/.claude.json" "${HOME}/.claude.json"; do
  [ -d "$_stale" ] && rm -rf "$_stale"
done

if [ -n "${CLAUDE_BOX_CLAUDE_MD:-}" ]; then
  echo "${CLAUDE_BOX_CLAUDE_MD}" | base64 -d > "${HOME}/.claude/CLAUDE.md"
  unset CLAUDE_BOX_CLAUDE_MD
fi
if [ -n "${CLAUDE_BOX_CREDENTIALS:-}" ]; then
  echo "${CLAUDE_BOX_CREDENTIALS}" | base64 -d > "${HOME}/.claude/.credentials.json"
  unset CLAUDE_BOX_CREDENTIALS
fi
if [ -n "${CLAUDE_BOX_CLAUDE_JSON:-}" ]; then
  echo "${CLAUDE_BOX_CLAUDE_JSON}" | base64 -d > "${HOME}/.claude.json"
  unset CLAUDE_BOX_CLAUDE_JSON
fi
if [ -n "${CLAUDE_BOX_SETTINGS:-}" ]; then
  echo "${CLAUDE_BOX_SETTINGS}" | base64 -d > "${HOME}/.claude/settings.json"
  unset CLAUDE_BOX_SETTINGS
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

  # Ensure home dir exists and is owned by the host user
  mkdir -p "${HOST_HOME}"
  chown "${HOST_UID}:${HOST_GID}" "${HOST_HOME}"

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
  echo "[entrypoint] launching claude $*" >&2
  exec gosu "${USERNAME}" claude "$@"
fi

# Already running as the right user (or root was requested)
exec claude "$@"
