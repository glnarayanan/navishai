# Desired config contains auto or a deliberate override, never a discovered host IP.
vps_public_listen_address() {
  local address="$1" octet
  local -a octets
  [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((10#$octet <= 255)) || return 1
  done
  ! ((10#${octets[0]} == 0 || 10#${octets[0]} == 10 || 10#${octets[0]} == 127 || 10#${octets[0]} >= 224 ||
      (10#${octets[0]} == 100 && 10#${octets[1]} >= 64 && 10#${octets[1]} <= 127) ||
      (10#${octets[0]} == 169 && 10#${octets[1]} == 254) ||
      (10#${octets[0]} == 172 && 10#${octets[1]} >= 16 && 10#${octets[1]} <= 31) ||
      (10#${octets[0]} == 192 && 10#${octets[1]} == 168)))
}

vps_resolve_ingress() {
  local desired="${1:-${VPS_INGRESS_OVERRIDE:-${NAVISHAI_PUBLIC_LISTEN_ADDRESS:-auto}}}" addresses routes candidates address device route
  local -a eligible=()
  unset VPS_PUBLIC_LISTEN_ADDRESS
  addresses="$(ip -j -4 address show up)" && routes="$(ip -j -4 route show table main default)" || { vps_die 'Cannot inspect host routing/interfaces.'; return 1; }
  candidates="$(jq -nr --argjson addresses "$addresses" --argjson routes "$routes" '
    [$routes[] | (.dev // .nexthops[]?.dev)] | unique as $devices |
    $addresses[] | select(.ifname != "lo" and (.ifname | startswith("tailscale") | not)) |
    select(.ifname as $dev | $devices | index($dev)) | .ifname as $dev |
    .addr_info[] | select(.scope == "global" and (.deprecated // false | not) and (.preferred_life_time // 1) != 0) |
    [.local, $dev] | @tsv')" || { vps_die 'Invalid host routing/interface response.'; return 1; }
  while IFS=$'\t' read -r address device; do
    [[ -n $address ]] || continue
    vps_public_listen_address "$address" || continue
    [[ $desired == auto || $desired == "$address" ]] || continue
    eligible+=("$address"$'\t'"$device")
  done <<< "$candidates"
  [[ ${#eligible[@]} == 1 ]] || { vps_die 'Ingress needs one assigned public IPv4 on a default-route interface. No safe unique choice; review topology, or use --public-listen-address with a deliberate valid override.'; return 1; }
  IFS=$'\t' read -r address device <<< "${eligible[0]}"
  route="$(ip -j -4 route get 1.1.1.1 from "$address")" || return 1
  jq -e --arg device "$device" 'length == 1 and .[0].dev == $device and ((.[0].type // "unicast") == "unicast")' <<< "$route" >/dev/null || { vps_die 'Selected public interface has no matching usable route; preserve VPN/access settings and review topology.'; return 1; }
  export VPS_PUBLIC_LISTEN_ADDRESS="$address"
}

vps_dns_check() {
  local records address
  records="$(getent ahostsv4 "$NAVISHAI_APP_HOST" | awk '{print $1}' | sort -u)" && [[ -n $records ]] || { vps_die 'Public hostname does not resolve to IPv4. Correct DNS before startup; proxy origin routing still needs operator verification.'; return 1; }
  while IFS= read -r address; do
    vps_public_listen_address "$address" || { vps_die 'Hostname resolves to a private/unsafe address; preserve access settings and correct public DNS.'; return 1; }
  done <<< "$records"
}

vps_ingress_check() {
  vps_resolve_ingress || return 1
  local listeners state received queued endpoint rest
  listeners="$(ss -ltnH '( sport = :80 or sport = :443 )')" || { vps_die 'Cannot inspect ingress listeners.'; return 1; }
  while read -r state received queued endpoint rest; do
    case "$endpoint" in
      "$VPS_PUBLIC_LISTEN_ADDRESS:80"|"$VPS_PUBLIC_LISTEN_ADDRESS:443"|127.0.0.1:443|0.0.0.0:80|0.0.0.0:443|\*:80|\*:443|\[::\]:80|\[::\]:443)
        vps_die "Ingress endpoint in use: $endpoint; preserve the listener and inspect ownership."; return 1 ;;
    esac
  done <<< "$listeners"
}

vps_ingress_binding_check() {
  vps_resolve_ingress || return 1
  local proxy metadata
  proxy="$(vps_compose ps --all -q proxy)" || return 1
  [[ $proxy =~ ^[0-9a-f]{64}$ ]] || return 1
  metadata="$(vps_docker inspect --format '{{json .HostConfig.PortBindings}}' "$proxy")" || return 1
  jq -e --arg address "$VPS_PUBLIC_LISTEN_ADDRESS" '
    keys == ["443/tcp","80/tcp"] and .["80/tcp"] == [{HostIp:$address,HostPort:"80"}] and
    (.["443/tcp"] | sort_by(.HostIp)) == ([{HostIp:$address,HostPort:"443"},{HostIp:"127.0.0.1",HostPort:"443"}] | sort_by(.HostIp))' <<< "$metadata" >/dev/null || { vps_die 'Proxy binding is stale or unsafe; writers must stop. Run gated start to reconcile automatic ingress.'; return 1; }
}

vps_write_ingress() {
  local desired="$1"
  [[ $desired == auto ]] || vps_public_listen_address "$desired" || return 1
  # Restore/upgrade must not rewrite an unchanged desired setting or its secrets.
  if grep -Fxq "NAVISHAI_PUBLIC_LISTEN_ADDRESS='$desired'" "$VPS_CONFIG/env"; then return 0; fi
  (umask 077; set -o noclobber; { sed '/^NAVISHAI_PUBLIC_LISTEN_ADDRESS=/d' "$VPS_CONFIG/env" && printf "\nNAVISHAI_PUBLIC_LISTEN_ADDRESS='%s'\n" "$desired"; } > "$VPS_CONFIG/env.new") &&
    chmod 600 -- "$VPS_CONFIG/env.new" && mv -f -- "$VPS_CONFIG/env.new" "$VPS_CONFIG/env"
}
