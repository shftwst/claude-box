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
if [ "$(id -u)" = "0" ] && [ "${HOST_UID}" != "0" ]; then
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

  # gosu does a direct exec as the user — no shell wrapper, proper TTY + signal
  # inheritance for Claude Code's interactive UI.
  exec gosu "${USERNAME}" claude "$@"
fi

# Already running as the right user (or root was requested)
exec claude "$@"
