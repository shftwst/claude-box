#!/usr/bin/env bash
# libcage.sh — the cage, once. Sourced by a thin per-payload wrapper
# (claude-box, codex-box, deepseek-box, pi-box). The cage owns the outer
# container, its security posture, the bounded nested engine, the ssh/colima
# relays, uid mapping, the image build, the exit-status contract, and the docker
# run assembly. The payload owns which harness command runs and which host state
# it syncs.
#
# A wrapper sets these before calling cage_run "$@":
#   BOX_LABEL         short name, e.g. claude-box / deepseek-box (logs, .env file)
#   BOX_SRC_DIR       dir holding Dockerfile.cage, entrypoint-cage.sh,
#                     userns-probe.sh, and the payload Dockerfile
#   BOX_IMAGE         payload image tag, e.g. claude-box
#   BOX_DOCKERFILE    payload Dockerfile path (FROM cage-base)
#   BOX_STATE_DIR     host state dir, e.g. ~/.claude-box/state
#   BOX_STATE_MOUNT   where the state dir mounts in-box, e.g. $HOME/.claude
#   BOX_ENV_PREFIX    env-knob prefix, e.g. CLAUDE_BOX / DEEPSEEK_BOX. Drives
#                     ${PREFIX}_EXTRA_VARS / _EXTRA_MOUNTS / _ENGINE_MODE /
#                     _DEBUG / _EXEC so each wrapper keeps its own interface.
#   BOX_FORWARD_VARS  array of extra env var names to forward (payload creds)
#   BOX_PAYLOAD_CMD   array: the harness argv the entrypoint execs (the wrapper
#                     appends the user's passthrough args to it)
#   BOX_RUN_ARGS      optional array: payload-owned docker-run arguments, such
#                     as a loopback-only published port for a browser UI
#
# A wrapper MAY define these hooks (all optional):
#   box_parse_arg "$@"   handle a wrapper-specific flag. Set _CONSUMED to the
#                        number of args eaten and return 0; return non-zero to
#                        let the cage treat "$1" as a passthrough arg.
#   box_prepare_payload after cage/project argument parsing and env loading,
#                        before payload argv assembly. May update
#                        BOX_PAYLOAD_CMD, HARNESS_ARGS, or BOX_RUN_ARGS.
#   box_stage            after the generic mounts are built: append to
#                        override_mounts / env_args, stage relay files, seed
#                        state. Sees STATE_DIR, PROJECT_DIR, PROJECT_SLUG, etc.
#   box_sync_back        from the EXIT trap after the container stops: copy
#                        payload state back to the host. Use cage_cp_out for the
#                        colima path.

# ---------------------------------------------------------------------------
# Logging — identical contract to the monolith.
# log(): tty-gated progress. Must never return nonzero under set -e.
log()   { [[ ! -t 2 ]] || printf '[%s] %s\n' "${BOX_LABEL:-cage}" "$*" >&2; }
# fault(): machine-readable launcher fault, UNCONDITIONAL on the tty.
fault() { printf '%s: fault=%s detail="%s"\n' "${BOX_LABEL:-cage}" "$1" "${2:-}" >&2; return 0; }
# warn(): machine-facing warning, UNCONDITIONAL on the tty.
warn()  { printf '[%s] WARNING: %s\n' "${BOX_LABEL:-cage}" "$*" >&2; }

# Fixed cage image the probes/helpers run against (payload-independent).
CAGE_IMAGE="cage-base"

# ---------------------------------------------------------------------------
# Update check — background, silent on every failure mode.
_cage_check_update_bg() {
  (
    cd "$BOX_SRC_DIR" || exit 0
    git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || exit 0
    git fetch --quiet 2>/dev/null || exit 0
    if [[ $(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0) -gt 0 ]]; then
      touch "$UPDATE_AVAILABLE_FILE"
    else
      rm -f "$UPDATE_AVAILABLE_FILE"
    fi
    touch "$UPDATE_CHECK_FILE"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Argument parsing. Generic cage flags (position-free, stripped before the
# harness sees them); a literal -- ends cage parsing. Unknown args go to the
# wrapper's box_parse_arg hook, then to the harness passthrough.
NO_SSH=0
UPGRADE=0
ENGINE_MODE=""
BOX_NAME=""
NAME_FILE=""
declare -a _passthrough=()
cage_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; _passthrough+=("$@"); break ;;
      --no-ssh) NO_SSH=1 ;;
      --upgrade) UPGRADE=1 ;;
      --engine)
        shift; ENGINE_MODE="${1:-}"
        [[ -n "$ENGINE_MODE" ]] || { printf '[%s] --engine requires a mode (auto|sysbox|rootless|privileged-dind|none)\n' "$BOX_LABEL" >&2; exit 1; } ;;
      --engine=*) ENGINE_MODE="${1#*=}" ;;
      --name)
        shift; BOX_NAME="${1:-}"
        [[ -n "$BOX_NAME" ]] || { printf '[%s] --name requires a container name\n' "$BOX_LABEL" >&2; exit 1; } ;;
      --name=*) BOX_NAME="${1#*=}" ;;
      --name-file)
        shift; NAME_FILE="${1:-}"
        [[ -n "$NAME_FILE" ]] || { printf '[%s] --name-file requires a path\n' "$BOX_LABEL" >&2; exit 1; } ;;
      --name-file=*) NAME_FILE="${1#*=}" ;;
      *)
        _CONSUMED=0
        if declare -F box_parse_arg >/dev/null && box_parse_arg "$@"; then
          shift "$(( _CONSUMED > 0 ? _CONSUMED - 1 : 0 ))"
        else
          _passthrough+=("$1")
        fi ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# Engine posture: probes, apparmor profile, userns ladder. Ported verbatim from
# the monolith; the only change is that helper containers run CAGE_IMAGE.
_dh_slug=""
_host_docker_caps=""

_probe_device() {
  local dev="$1" cache="${HOME}/.claude-box/.device-probe-${1//\//_}-${_dh_slug}"
  if [[ ! -f "$cache" ]]; then
    if docker run --rm --entrypoint true --device "$dev" "$CAGE_IMAGE" >/dev/null 2>&1; then
      echo yes > "$cache"
    else
      echo no > "$cache"
    fi
  fi
  [[ "$(cat "$cache" 2>/dev/null)" == yes ]]
}

_USERNS_PROFILE='abi <abi/4.0>,
include <tunables/global>
profile claude-box-engine flags=(unconfined) {
  userns,
}'

_load_userns_profile() {
  printf '%s\n' "$_USERNS_PROFILE" | docker run --rm -i --privileged --pid=host \
    --entrypoint nsenter "$CAGE_IMAGE" -t 1 -m -- sh -c \
    'cat > /run/claude-box-engine.profile && apparmor_parser -Kr /run/claude-box-engine.profile' \
    >/dev/null 2>&1
}

_userns_probe() {
  docker run --rm --entrypoint /usr/local/bin/claude-box-userns-probe \
    --security-opt seccomp=unconfined "$@" "$CAGE_IMAGE" >/dev/null 2>&1
}

_resolve_userns_strategy() {
  local cache="${HOME}/.claude-box/.userns-strategy-${_dh_slug}" s="" aa=()
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
  [[ "$_host_docker_caps" == *apparmor* ]] && aa=(--security-opt apparmor=unconfined)
  if _userns_probe ${aa[@]+"${aa[@]}"}; then
    s="plain"
  elif [[ "$_host_docker_caps" == *apparmor* ]] && _load_userns_profile; then
    if _userns_probe --security-opt apparmor=claude-box-engine; then
      s="profile"
    elif _userns_probe --security-opt apparmor=claude-box-engine --cap-add SYS_ADMIN; then
      s="profile-cap"
    fi
  fi
  if [[ -z "$s" ]] && _userns_probe ${aa[@]+"${aa[@]}"} --cap-add SYS_ADMIN; then
    s="cap"
  fi
  if [[ -n "$s" ]]; then echo "$s" > "$cache"; echo "$s"; else echo "unsupported"; fi
}

# Resolve ENGINE from ENGINE_MODE (CLI) / ${PREFIX}_ENGINE_MODE / auto, then
# build engine_args. Sets globals ENGINE and engine_args.
cage_resolve_engine() {
  local envmode_var="${BOX_ENV_PREFIX}_ENGINE_MODE"
  ENGINE_MODE="${ENGINE_MODE:-${!envmode_var:-auto}}"
  _host_docker_caps=""
  if [[ "$ENGINE_MODE" != "none" ]]; then
    _host_docker_caps="$(docker info --format '{{.SecurityOptions}} {{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null || true)"
  fi
  case "$ENGINE_MODE" in
    auto)
      if [[ "$_host_docker_caps" == *sysbox-runc* ]]; then ENGINE=sysbox; else ENGINE=rootless; fi ;;
    sysbox)
      if [[ "$_host_docker_caps" != *sysbox-runc* ]]; then
        fault engine-start-failed "--engine sysbox: host docker has no sysbox-runc runtime (install sysbox first)"
        exit 126
      fi
      ENGINE=sysbox ;;
    rootless|privileged-dind|none) ENGINE="$ENGINE_MODE" ;;
    *)
      printf '[%s] unknown --engine mode: %s (want auto|sysbox|rootless|privileged-dind|none)\n' "$BOX_LABEL" "$ENGINE_MODE" >&2
      exit 1 ;;
  esac

  _dh_slug="$(printf '%s' "${DOCKER_HOST:-default}" | tr -c 'a-zA-Z0-9' '_')"
  engine_args=()
  case "$ENGINE" in
    sysbox)
      engine_args+=(--runtime sysbox-runc -e "CAGE_ENGINE=rootful" --init)
      log "engine: sysbox (rootful nested dockerd, bounded by sysbox-runc)" ;;
    rootless)
      engine_args+=(
        --security-opt seccomp=unconfined
        --security-opt systempaths=unconfined
        -e "CAGE_ENGINE=rootless"
        -v /var/lib/claude-box-engine
        --init
      )
      local strat; strat="$(_resolve_userns_strategy)"
      case "$strat" in
        plain)
          [[ "$_host_docker_caps" == *apparmor* ]] && engine_args+=(--security-opt apparmor=unconfined) ;;
        profile|profile-cap)
          _load_userns_profile || warn "apparmor profile load failed: engine may not start"
          engine_args+=(--security-opt apparmor=claude-box-engine)
          [[ "$strat" == profile-cap ]] && engine_args+=(--cap-add SYS_ADMIN) ;;
        cap)
          engine_args+=(--cap-add SYS_ADMIN) ;;
        unsupported)
          warn "this docker host cannot give an unprivileged user a capable user"
          warn "namespace, so the rootless nested engine will likely fail to start."
          warn "consider sysbox, or '--engine privileged-dind' (ADR-0041's named"
          warn "weaker posture), or '--engine none'."
          [[ "$_host_docker_caps" == *apparmor* ]] && engine_args+=(--security-opt apparmor=unconfined) ;;
      esac
      _probe_device /dev/net/tun && engine_args+=(--device /dev/net/tun)
      _probe_device /dev/fuse && engine_args+=(--device /dev/fuse)
      log "engine: rootless nested dockerd (userns strategy: ${strat})" ;;
    privileged-dind)
      warn "--engine privileged-dind is ADR-0041's named weaker posture:"
      warn "a privileged cage weakens host isolation. Prefer sysbox or rootless."
      engine_args+=(--privileged -e "CAGE_ENGINE=rootful" -v /var/lib/docker --init) ;;
    none)
      # --init here too, so all four postures agree: tini reaps zombies and
      # forwards signals uniformly even without a nested engine.
      engine_args+=(-e "CAGE_ENGINE=none" --init)
      log "engine: none (no container engine inside the box)" ;;
  esac
}

# ---------------------------------------------------------------------------
# SSH mounts + colima ssh-agent relay. Ported verbatim; appends to
# override_mounts / env_args and sets _SSH_RELAY_PID.
_SSH_RELAY_PID=""
cage_setup_ssh() {
  if [[ $NO_SSH -ne 0 ]]; then
    log "ssh disabled (--no-ssh): no key mount, no agent forwarding"
    return 0
  fi
  [[ -d "${HOME}/.ssh" ]] && override_mounts+=(-v "${HOME}/.ssh:${HOME}/.ssh:ro")
  [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]] || return 0
  if [[ "${DOCKER_HOST:-}" == */.colima/* ]]; then
    local relay_port_file; relay_port_file=$(mktemp /tmp/claude-box-relay.XXXXXX)
    python3 -c "
import socket, sys, threading, signal, os
src = '${SSH_AUTH_SOCK}'
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 0))
port = server.getsockname()[1]
with open('${relay_port_file}', 'w') as f:
    f.write(str(port))
server.listen(8)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
def relay(a, b):
    try:
        while d := a.recv(4096): b.sendall(d)
    except: pass
    finally: a.close(); b.close()
while True:
    c, _ = server.accept()
    u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    u.connect(src)
    threading.Thread(target=relay, args=(c, u), daemon=True).start()
    threading.Thread(target=relay, args=(u, c), daemon=True).start()
" &
    _SSH_RELAY_PID=$!
    local port="" i
    for i in $(seq 1 30); do
      [[ -s "$relay_port_file" ]] && { port=$(<"$relay_port_file"); break; }
      sleep 0.1
    done
    rm -f "$relay_port_file"
    if [[ -z "$port" ]]; then
      warn "SSH agent relay failed to start: signing will not work"
      kill "$_SSH_RELAY_PID" 2>/dev/null || true
      _SSH_RELAY_PID=""
    else
      env_args+=(-e "CAGE_SSH_RELAY_PORT=${port}")
      env_args+=(--add-host "host.docker.internal:host-gateway")
    fi
  elif [[ "$SSH_AUTH_SOCK" == /private/tmp/com.apple.launchd.* ]]; then
    override_mounts+=(-v "/run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock")
    env_args+=(-e "SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock")
  else
    override_mounts+=(-v "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}")
    env_args+=(-e "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}")
  fi
}

# ---------------------------------------------------------------------------
# Generic relay staging: host gitconfig into the cage-owned relay dir under the
# state volume, where entrypoint-cage.sh copies it to ~/.gitconfig. The AGENTS.md
# merge is a payload concern (the payload writes ${RELAY_DIR}/AGENTS.md in box_stage).
RELAY_DIR=""
cage_stage_gitconfig() {
  RELAY_DIR="${STATE_DIR}/.cage-relay"
  mkdir -p "$RELAY_DIR" 2>/dev/null || true
  # If a prior run left the relay dir owned by a subuid the host user can't write
  # (rootless-engine uid mapping), skip the relay rather than abort the launch.
  # entrypoint-cage.sh tolerates missing relay files; box_stage checks RELAY_DIR.
  if [[ ! -w "$RELAY_DIR" ]]; then
    warn "relay dir not writable (${RELAY_DIR}); skipping host->box gitconfig/AGENTS.md relay"
    RELAY_DIR=""
    return 0
  fi
  [[ -f "${HOME}/.gitconfig" ]] && cp -f "${HOME}/.gitconfig" "${RELAY_DIR}/gitconfig" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Colima helpers, used by cage_sync_back / box_sync_back.
_CID=""
# cage_cp_out <rel-under-state>: on colima pull the path out of the state volume
# through docker I/O; elsewhere the host already sees the bind-mounted state dir.
cage_cp_out() {
  [[ -n "$_CID" ]] || return 0
  docker cp "${_CID}:/_state/${1}" "${STATE_DIR}/${1}" 2>/dev/null || true
}

# Flush the whole state dir into the colima VM through docker I/O so the VM sees
# freshly-written host files at mount time. No-op off colima.
cage_flush_state_to_vm() {
  [[ "${DOCKER_HOST:-}" == */.colima/* ]] || return 0
  log "flushing state for colima..."
  tar --no-xattrs -cf - -C "${STATE_DIR}" . 2>/dev/null \
    | docker run --rm -i --entrypoint tar -v "${STATE_DIR}:/_state" "${CAGE_IMAGE}" --no-same-owner -xf - -C /_state 2>/dev/null || true
}

_LAUNCHED=0
_SYNCED=0
cage_sync_back() {
  [[ "${_LAUNCHED:-0}" == 1 && "${_SYNCED:-0}" == 0 ]] || return 0
  _SYNCED=1
  set +euo pipefail
  # Never copy out from a container still writing to the state volume.
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker stop -t 2 "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  _CID=""
  if [[ "${DOCKER_HOST:-}" == */.colima/* ]]; then
    _CID=$(docker create --entrypoint sleep -v "${STATE_DIR}:/_state:rw" "${CAGE_IMAGE}" 1 2>/dev/null)
  fi
  declare -F box_sync_back >/dev/null && box_sync_back
  [[ -n "$_CID" ]] && docker rm -f "$_CID" >/dev/null 2>&1 || true
}

cage_cleanup() {
  if [[ -n "$_SSH_RELAY_PID" ]]; then
    kill "$_SSH_RELAY_PID" 2>/dev/null || true
    wait "$_SSH_RELAY_PID" 2>/dev/null || true
  fi
  [[ -n "$NAME_FILE" ]] && rm -f "$NAME_FILE"
}

# ---------------------------------------------------------------------------
# Image build: cage-base first (from its own inputs), then the payload image.
cage_build_images() {
  local cage_df="${BOX_SRC_DIR}/Dockerfile.cage"
  local cage_entry="${BOX_SRC_DIR}/entrypoint-cage.sh"
  local probe="${BOX_SRC_DIR}/userns-probe.sh"
  local cage_marker="${HOME}/.claude-box/.built-cage"

  local need=0
  if ! docker image inspect "$CAGE_IMAGE" &>/dev/null; then need=1
  elif [[ "$cage_df" -nt "$cage_marker" || "$cage_entry" -nt "$cage_marker" || "$probe" -nt "$cage_marker" ]]; then need=1; fi
  if [[ $need -eq 1 ]]; then
    log "building cage-base image..."
    if ! docker build -f "$cage_df" -t "$CAGE_IMAGE" "$BOX_SRC_DIR"; then
      fault image-missing "docker build failed for image '${CAGE_IMAGE}'"
      exit 125
    fi
    mkdir -p "$(dirname "$cage_marker")"; touch "$cage_marker"
  fi

  local marker="${HOME}/.claude-box/.built-${BOX_LABEL}"
  need=0
  if ! docker image inspect "$BOX_IMAGE" &>/dev/null; then need=1
  elif [[ "$BOX_DOCKERFILE" -nt "$marker" || "$cage_marker" -nt "$marker" ]]; then need=1
  else
    # Extra build inputs the payload Dockerfile COPYs (payload-init, theme, ...):
    # a change to any must force a rebuild too, since the Dockerfile itself is
    # unchanged. BOX_BUILD_INPUTS is a wrapper-set array of absolute paths.
    local _in
    for _in in "${BOX_BUILD_INPUTS[@]+"${BOX_BUILD_INPUTS[@]}"}"; do
      [[ "$_in" -nt "$marker" ]] && { need=1; break; }
    done
  fi
  if [[ $need -eq 1 ]]; then
    log "building ${BOX_LABEL} image..."
    if ! docker build -f "$BOX_DOCKERFILE" -t "$BOX_IMAGE" "$BOX_SRC_DIR"; then
      fault image-missing "docker build failed for image '${BOX_IMAGE}'"
      exit 125
    fi
    mkdir -p "$(dirname "$marker")"; touch "$marker"
  fi

  if ! docker image inspect "$BOX_IMAGE" >/dev/null 2>&1; then
    fault image-missing "image '${BOX_IMAGE}' is not present (build it or check the docker daemon)"
    exit 125
  fi
}

# ---------------------------------------------------------------------------
# Main entry.
cage_run() {
  cage_parse_args "$@"
  set -- "${_passthrough[@]+"${_passthrough[@]}"}"

  if [[ -n "$BOX_NAME" && ! "$BOX_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    printf '[%s] --name: invalid container name (allowed: [a-zA-Z0-9][a-zA-Z0-9_.-]*)\n' "$BOX_LABEL" >&2
    exit 1
  fi

  # Plain assignment: inside a function an unqualified assignment is global,
  # which is what we want, and it stays bash-3.2-safe (no `declare -g`).
  HARNESS_ARGS=("$@")

  mkdir -p "${HOME}/.claude-box"
  UPDATE_CHECK_FILE="${HOME}/.claude-box/.last-update-check-${BOX_LABEL}"
  UPDATE_AVAILABLE_FILE="${HOME}/.claude-box/.update-available-${BOX_LABEL}"

  if [[ $UPGRADE -eq 1 ]]; then
    log "upgrading ${BOX_LABEL} at ${BOX_SRC_DIR}..."
    if git -C "$BOX_SRC_DIR" pull --ff-only; then
      rm -f "$UPDATE_AVAILABLE_FILE"; touch "$UPDATE_CHECK_FILE"; exit 0
    else
      exit $?
    fi
  fi
  [[ -e "$UPDATE_AVAILABLE_FILE" ]] && log "update available — run '${BOX_LABEL} --upgrade' to pull latest"
  if [[ ! -f "$UPDATE_CHECK_FILE" ]] || [[ -z "$(find "$UPDATE_CHECK_FILE" -mtime -1 2>/dev/null)" ]]; then
    _cage_check_update_bg
  fi

  PROJECT_DIR="$(pwd)"
  local home_real; home_real="$(cd "$HOME" 2>/dev/null && pwd)"
  if [[ -n "$home_real" && ( "$PROJECT_DIR" == "$home_real" || "$home_real" == "$PROJECT_DIR"/* ) ]]; then
    printf '[%s] refusing to launch from %s\n' "$BOX_LABEL" "$PROJECT_DIR" >&2
    printf '[%s] this would bind-mount your entire home directory (%s) into the box.\n' "$BOX_LABEL" "$home_real" >&2
    printf '[%s] cd into a specific project directory and run %s from there.\n' "$BOX_LABEL" "$BOX_LABEL" >&2
    exit 1
  fi

  cage_build_images

  STATE_DIR="$BOX_STATE_DIR"
  mkdir -p "$STATE_DIR"
  # 777 lets the in-box user (any uid) write to the state volume. Tolerate a
  # failure: after a prior run the entrypoint's chown can leave the dir owned by
  # a subuid the host user can't chmod (rootless-engine uid mapping) — it stays
  # writable regardless, so this is not worth aborting the launch for.
  chmod 777 "$STATE_DIR" 2>/dev/null || true

  CONTAINER_NAME="${BOX_NAME:-${BOX_LABEL}-$(basename "$PROJECT_DIR")-$$}"

  trap 'cage_sync_back; cage_cleanup' EXIT
  trap 'exit' INT TERM HUP

  # Per-project overrides from ${PROJECT_DIR}/.env.<label>.
  local proj_env="${PROJECT_DIR}/.env.${BOX_LABEL}"
  if [[ -f "$proj_env" ]]; then
    set -a; # shellcheck disable=SC1090
    source "$proj_env"; set +a
  fi

  cage_resolve_engine

  # Env forwarding: generic base + the payload's extras + the wrapper's
  # ${PREFIX}_EXTRA_VARS. TERM/COLORFGBG only when set (never synthesize).
  local extra_vars_name="${BOX_ENV_PREFIX}_EXTRA_VARS"
  local FORWARD_VARS
  FORWARD_VARS=(
    GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN TERM COLORFGBG
    "${BOX_FORWARD_VARS[@]+"${BOX_FORWARD_VARS[@]}"}"
  )
  # Append the array named by $extra_vars_name (dynamic name). bash 3.2 has no
  # namerefs, so indirect via eval, guarded so an unset var is a no-op under set -u.
  if eval "[ -n \"\${${extra_vars_name}[*]+x}\" ]" 2>/dev/null; then
    eval "FORWARD_VARS+=( \"\${${extra_vars_name}[@]}\" )"
  fi
  env_args=()
  local var
  for var in "${FORWARD_VARS[@]}"; do
    [[ -n "${!var:-}" ]] && env_args+=(-e "${var}=${!var}")
  done
  # ${PREFIX}_DEBUG -> generic CAGE_DEBUG the entrypoint reads.
  local dbg_var="${BOX_ENV_PREFIX}_DEBUG"
  [[ -n "${!dbg_var:-}" ]] && env_args+=(-e "CAGE_DEBUG=1")

  # ${PREFIX}_EXEC: run the passthrough args as a bare command instead of the
  # payload (the generic form of the old CLAUDE_BOX_EXEC acceptance hook).
  local exec_var="${BOX_ENV_PREFIX}_EXEC"
  # BOX_PAYLOAD_CMD is the base harness argv (e.g. `claude --dangerously-skip-
  # permissions`); the cage appends the user's passthrough args. The exec hook
  # replaces the whole command with the bare passthrough args.
  declare -a PAYLOAD_CMD
  if [[ -n "${!exec_var:-}" ]]; then
    PAYLOAD_CMD=("${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}")
    log "exec hook (${exec_var}): running passthrough args as the in-box command"
  else
    declare -F box_prepare_payload >/dev/null && box_prepare_payload
    PAYLOAD_CMD=("${BOX_PAYLOAD_CMD[@]}" "${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}")
  fi

  # gh token so `gh` works in-box without re-auth.
  if [[ -z "${GH_TOKEN:-}" ]]; then
    log "fetching gh auth token..."
    GH_TOKEN=$(gh auth token 2>/dev/null) && env_args+=(-e "GH_TOKEN=${GH_TOKEN}") || true
  fi

  override_mounts=()
  cage_setup_ssh
  cage_stage_gitconfig

  # Share XDG cache and ~/.local/bin across boxes (generic).
  mkdir -p "${HOME}/.cache"; override_mounts+=(-v "${HOME}/.cache:${HOME}/.cache")
  mkdir -p "${HOME}/.local/bin"; override_mounts+=(-v "${HOME}/.local/bin:${HOME}/.local/bin")

  PROJECT_SLUG="${PROJECT_DIR//\//-}"

  # Per-project extra mounts from ${PREFIX}_EXTRA_MOUNTS (dynamic name; indirect
  # via eval for bash 3.2, guarded so an unset var is a no-op under set -u).
  local extra_mounts_name="${BOX_ENV_PREFIX}_EXTRA_MOUNTS"
  local spec
  if eval "[ -n \"\${${extra_mounts_name}[*]+x}\" ]" 2>/dev/null; then
    eval "for spec in \"\${${extra_mounts_name}[@]}\"; do override_mounts+=( -v \"\$spec\" ); done"
  fi

  # Payload staging: its own mounts, relay files (AGENTS.md), state seeding.
  declare -F box_stage >/dev/null && box_stage

  cage_flush_state_to_vm

  # Terminal title.
  [[ -t 2 ]] && printf '\e]0;%s: %s\a' "$BOX_LABEL" "$(basename "$PROJECT_DIR")" >&2

  TTY_FLAGS=()
  if [[ -t 0 || -p /dev/stdin || -f /dev/stdin || -S /dev/stdin ]]; then TTY_FLAGS+=(-i); fi
  if [[ -t 1 && -t 2 ]]; then TTY_FLAGS+=(-t); fi

  log "starting container..."
  _LAUNCHED=1
  local rc=0

  if [[ -n "$NAME_FILE" ]]; then
    printf '%s\n' "$CONTAINER_NAME" > "$NAME_FILE" || warn "--name-file: could not write ${NAME_FILE}"
  fi

  docker run --rm "${TTY_FLAGS[@]}" \
    --name "$CONTAINER_NAME" \
    ${BOX_RUN_ARGS[@]+"${BOX_RUN_ARGS[@]}"} \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    -e "HOME=${HOME}" \
    -e "CAGE_STATE_MOUNT=${BOX_STATE_MOUNT}" \
    -e "GIT_CONFIG_COUNT=3" \
    -e "GIT_CONFIG_KEY_0=safe.directory" \
    -e "GIT_CONFIG_VALUE_0=*" \
    -e "GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf" \
    -e "GIT_CONFIG_VALUE_1=git@github.com:" \
    -e "GIT_CONFIG_KEY_2=credential.helper" \
    -e "GIT_CONFIG_VALUE_2=!gh auth git-credential" \
    -v "${PROJECT_DIR}:${PROJECT_DIR}" \
    -v "${STATE_DIR}:${BOX_STATE_MOUNT}" \
    ${override_mounts[@]+"${override_mounts[@]}"} \
    ${engine_args[@]+"${engine_args[@]}"} \
    ${env_args[@]+"${env_args[@]}"} \
    -w "${PROJECT_DIR}" \
    "$BOX_IMAGE" \
    "${PAYLOAD_CMD[@]}" || rc=$?

  case "$rc" in
    125) fault engine-start-failed "docker could not create/start the container (check --engine posture and host runtime)"; rc=126 ;;
    126|127) fault harness-not-executable "the container could not exec the harness (not found or not executable)"; rc=127 ;;
  esac
  exit "$rc"
}
