#!/bin/bash
# Claude payload-init — run by the cage entrypoint (as root, before the engine)
# for Claude-specific in-box prep the generic cage doesn't do. HOME and
# CAGE_STATE_MOUNT (== ${HOME}/.claude) are already set.
set -e

# Clean up stale directories that Docker auto-creates when a bind-mount source
# doesn't exist. On Colima this is common because virtiofs cache delays can make
# freshly-written host files invisible to the VM at mount time. These root-owned
# directories persist in the state volume and shadow the real files on subsequent
# runs, so remove them at startup. Only paths inside the state volume
# (${HOME}/.claude); ${HOME}/.claude.json is a separate bind mount.
for _stale in "${HOME}/.claude/CLAUDE.md" "${HOME}/.claude/.credentials.json" \
              "${HOME}/.claude/.claude.json" "${HOME}/.claude/settings.json"; do
  [ -d "$_stale" ] && rm -rf "$_stale"
done

# Install the baked-in claude-box theme so the container is visually distinct.
mkdir -p "${HOME}/.claude/themes"
cp -f /usr/local/share/claude-box-theme.json "${HOME}/.claude/themes/claude-box.json" 2>/dev/null || true
