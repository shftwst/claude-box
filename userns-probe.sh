#!/bin/bash
# claude-box userns probe — exits 0 iff an unprivileged user in this container
# can create a CAPABLE nested user namespace: unshare(CLONE_NEWUSER) plus a
# parent-side multi-range newuidmap/newgidmap, which is exactly what
# rootlesskit needs to boot the rootless nested engine. The launcher runs this
# under candidate security-option sets to pick the weakest set that works
# (Ubuntu's apparmor_restrict_unprivileged_userns kernels need an apparmor
# profile with the userns permission, and CAP_SYS_ADMIN in the bounding set
# for the setuid newuidmap helpers). Runs as container root; throwaway user.
set -e
useradd --non-unique -u 60001 -s /usr/sbin/nologin -M claude-box-probe 2>/dev/null || true
PGID="$(id -g claude-box-probe)"
grep -q '^claude-box-probe:' /etc/subuid 2>/dev/null || echo 'claude-box-probe:100000:65536' >> /etc/subuid
grep -q '^claude-box-probe:' /etc/subgid 2>/dev/null || echo 'claude-box-probe:100000:65536' >> /etc/subgid
exec gosu claude-box-probe bash -ec '
  unshare -U sleep 3 &
  pid=$!
  sleep 0.3
  newuidmap "$pid" 0 60001 1 1 100000 65536
  newgidmap "$pid" 0 '"$PGID"' 1 1 100000 65536
'
