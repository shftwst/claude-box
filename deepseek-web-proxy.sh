#!/usr/bin/env bash
# Keep DeepSeek Harness on the loopback address it requires while making it
# reachable through a Docker port published on the host's loopback address.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  printf 'usage: deepseek-web-proxy <ui-port> <bridge-port> [dsh web args...]\n' >&2
  exit 2
fi

ui_port="$1"
bridge_port="$2"
shift 2

proxy_pid=""
dsh_pid=""
signal_rc=0

stop_children() {
  local signal="${1:-TERM}"
  [[ -n "$dsh_pid" ]] && kill -"$signal" "$dsh_pid" 2>/dev/null || true
  [[ -n "$proxy_pid" ]] && kill -"$signal" "$proxy_pid" 2>/dev/null || true
}

# Invoked indirectly by the signal traps below.
# shellcheck disable=SC2329
handle_signal() {
  case "$1" in
    TERM) signal_rc=143 ;;
    INT)  signal_rc=130 ;;
    HUP)  signal_rc=129 ;;
  esac
  stop_children "$1"
}

trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP

# Docker forwards host loopback to bridge_port on the container interface.
# socat then crosses into the container loopback address where dsh is allowed
# to listen. The browser's Host/Origin headers remain the original loopback
# authority, preserving Harness's DNS-rebinding and cross-site request fence.
socat "TCP-LISTEN:${bridge_port},bind=0.0.0.0,reuseaddr,fork" \
  "TCP:127.0.0.1:${ui_port}" &
proxy_pid=$!

dsh web --host 127.0.0.1 --port "$ui_port" --no-open "$@" &
dsh_pid=$!

# Exit when either half exits. A failed bridge is fatal; a normal Harness exit
# keeps the Harness status. Container teardown then cannot leave an orphan.
set +e
wait -n "$proxy_pid" "$dsh_pid"
rc=$?
set -e

if [[ $signal_rc -ne 0 ]]; then
  rc=$signal_rc
elif kill -0 "$dsh_pid" 2>/dev/null; then
  printf '[deepseek-box] Web UI bridge exited unexpectedly\n' >&2
  [[ $rc -ne 0 ]] || rc=1
fi

stop_children TERM
wait "$dsh_pid" 2>/dev/null || true
wait "$proxy_pid" 2>/dev/null || true
exit "$rc"
