# Metadata-only shell fixture. Never enters a namespace or calls Docker.
VPS_PROJECT=navishai-reset
vps_compose() {
  case ${@: -1} in
    app-net) printf '%s\n' "${HOLDER_IDS:-$HOLDER}" ;;
    postgres) printf '%s\n' "$POSTGRES" ;;
    *) return 1 ;;
  esac
}
vps_docker() {
  local id=${@: -1}
  if [[ $1 == inspect ]]; then
    case $id in
      "$HOLDER") printf '%s\n' "$HOLDER_INFO" ;;
      "$POSTGRES") printf '%s\n' "$POSTGRES_INFO" ;;
      *) return 1 ;;
    esac
  elif [[ $1 == network && $2 == inspect ]]; then
    local net=control internal=true
    [[ $id != "$EDGE" ]] || { net=edge; internal=false; }
    printf '%s\n' "$id|${NETWORK_NAME:-navishai-reset_$net}|${NETWORK_OWNER:-navishai-reset}|${NETWORK_PROJECT:-navishai-reset}|$net|bridge|${NETWORK_INTERNAL:-$internal}"
  else
    return 1
  fi
}
stat() {
  case ${@: -1} in
    /proc/self/ns/net) echo 100 ;;
    /proc/1/ns/net) echo 101 ;;
    /proc/1234/ns/net) echo "${NAMESPACE:-102}" ;;
    *) return 1 ;;
  esac
}
