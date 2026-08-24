#!/usr/bin/env bash

compose() {
  docker compose "$@"
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
  compose up -d supermemory runner web jobs
}

stop_application() {
  compose stop jobs web runner supermemory
}
