#!/usr/bin/env bash

compose() {
  docker compose "$@"
}

require_operation_lock() {
  local root state
  [[ ${NAVISHAI_OPERATION_LOCK_HELD:-} == 1 ]] && return
  root="$(pwd -P)"
  case "$root" in
    */opt/navishai/releases/*) state="${root%/opt/navishai/releases/*}/var/lib/navishai" ;;
    *) return ;;
  esac
  command -v flock >/dev/null 2>&1 || {
    printf 'flock is required.\n' >&2
    exit 1
  }
  mkdir -p "$state"
  exec {operation_lock_fd}>"$state/install.lock"
  flock -n "$operation_lock_fd" || {
    printf 'Another mutating NavishAI operation is running. Use navishai to run this command.\n' >&2
    exit 1
  }
}

memory_pending() {
  [[ -n ${COMPOSE_ENV_FILES:-} && -f $COMPOSE_ENV_FILES ]] && grep -qx 'NAVISHAI_MEMORY_PENDING=1' "$COMPOSE_ENV_FILES"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '%s is required.\n' "$1" >&2
    exit 1
  }
}

require_archive() {
  local archive="$1"
  [[ -d "$archive" ]] || {
    printf 'Backup archive does not exist: %s\n' "$archive" >&2
    exit 1
  }
}

start_application() {
  compose up -d runner web jobs
  memory_pending || compose up -d supermemory
}

stop_application() {
  compose stop jobs web runner supermemory
}
