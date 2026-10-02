# Source from the root-only VPS CLI. The caller owns stopping workloads on error
# and startup ordering; this unit never starts containers or changes host policy.

_vps_policy_error() {
  printf 'VPS policy: %s\n' "$*" >&2
  return 1
}

_vps_policy_inspect() {
  local holder postgres info pginfo control edge net data
  [[ ${VPS_PROJECT:-} == navishai-reset ]] || { _vps_policy_error 'wrong project'; return 1; }
  holder=$(vps_compose ps --all --quiet app-net) || return 1
  postgres=$(vps_compose ps --all --quiet postgres) || return 1
  [[ $holder =~ ^[0-9a-f]{64}$ && $postgres =~ ^[0-9a-f]{64}$ && $holder != "$postgres" ]] || {
    _vps_policy_error 'need exactly one app-net and postgres container'; return 1;
  }
  # Read no environment or credentials. Delimiters and every accepted field are
  # checked below, including exact network membership rather than name prefixes.
  local format='{{.Id}}|{{index .Config.Labels "com.navishai.owner"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Pid}}|{{.State.Running}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.RestartPolicy.Name}}'
  info=$(vps_docker inspect --type container --format "$format|{{.Config.User}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.SecurityOpt}}|{{len .NetworkSettings.Networks}}|{{with index .NetworkSettings.Networks \"${VPS_PROJECT}_control\"}}{{.NetworkID}}|{{.IPAddress}}|{{.GlobalIPv6Address}}{{end}}|{{with index .NetworkSettings.Networks \"${VPS_PROJECT}_edge\"}}{{.NetworkID}}|{{.IPAddress}}|{{.GlobalIPv6Address}}{{end}}" "$holder") || return 1
  pginfo=$(vps_docker inspect --type container --format "$format|{{len .NetworkSettings.Networks}}|{{with index .NetworkSettings.Networks \"${VPS_PROJECT}_control\"}}{{.NetworkID}}|{{.IPAddress}}|{{.GlobalIPv6Address}}{{end}}" "$postgres") || return 1
  [[ $info != *$'\n'* && $pginfo != *$'\n'* ]] || return 1
  local id owner project service pid running privileged mode restart uid drop add security count address control6 edgeaddress edge6 extra pgpid pgaddress pg6
  IFS='|' read -r id owner project service pid running privileged mode restart uid drop add security count control address control6 edge edgeaddress edge6 extra <<< "$info"
  [[ $id == "$holder" && $owner == navishai-reset && $project == "$VPS_PROJECT" && $service == app-net &&
     $pid =~ ^[1-9][0-9]*$ && $pid -gt 1 && $running == true && $privileged == false &&
     ( $mode == "${VPS_PROJECT}_control" || $mode == "${VPS_PROJECT}_edge" ) && $restart == no &&
     $uid == 1000:1000 && $drop == '["ALL"]' && ( $add == null || $add == '[]' ) &&
     ( $security == '["no-new-privileges:true"]' || $security == '["no-new-privileges"]' ) &&
     $count == 2 && $control =~ ^[0-9a-f]{64}$ && $edge =~ ^[0-9a-f]{64}$ && $control != "$edge" && -z $extra ]] || {
    _vps_policy_error 'invalid holder ownership, privileges or topology'; return 1;
  }
  _vps_policy_ipv4 "$address" || return 1
  _vps_policy_ipv4 "$edgeaddress" || return 1
  IFS='|' read -r id owner project service pgpid running privileged mode restart count net pgaddress pg6 extra <<< "$pginfo"
  [[ $id == "$postgres" && $owner == navishai-reset && $project == "$VPS_PROJECT" && $service == postgres &&
     $pgpid =~ ^[1-9][0-9]*$ && $pgpid -gt 1 && $running == true && $privileged == false &&
     $mode == "${VPS_PROJECT}_control" && $restart == no && $count == 1 && $net == "$control" &&
     -z $pg6 && -z $extra ]] || { _vps_policy_error 'invalid postgres ownership or topology'; return 1; }
  _vps_policy_ipv4 "$pgaddress" || return 1
  [[ $address != "$pgaddress" ]] || return 1
  for net in control edge; do
    data=$(vps_docker network inspect --format '{{.Id}}|{{.Name}}|{{index .Labels "com.navishai.owner"}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.network"}}|{{.Driver}}|{{.Internal}}' "${!net}") || return 1
    local internal=false
    [[ $net == control ]] && internal=true
    [[ $data == "${!net}|${VPS_PROJECT}_${net}|navishai-reset|${VPS_PROJECT}|${net}|bridge|${internal}" ]] || {
      _vps_policy_error 'invalid network ownership or topology'; return 1;
    }
  done
  local inode self host
  inode=$(stat -Lc '%i' "/proc/$pid/ns/net") || return 1
  self=$(stat -Lc '%i' /proc/self/ns/net) || return 1
  host=$(stat -Lc '%i' /proc/1/ns/net) || return 1
  [[ $inode =~ ^[0-9]+$ && $inode != "$self" && $inode != "$host" ]] || {
    _vps_policy_error 'shared/host namespace refused'; return 1;
  }
  printf '%s\n%s\n%s\n%s\n' "$info" "$pginfo" "$inode" "$pgaddress"
}

_vps_policy_ipv4() {
  local octets octet
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet =~ ^[1-9][0-9]{0,2}$ ]] && ((10#$octet <= 255)) || return 1
  done
  [[ $1 != 0.0.0.0 && $1 != 127.* ]] || return 1
}

_vps_policy_rules() {
  local family=$1 postgres=$2 range reject
  # Keep aligned with Operations::EdgePolicy and EvaluationHttp. No endpoint
  # disclosure approval follows from being a routable public address.
  local -a blocked4=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3)
  local -a blocked6=(2001::/23 2001:db8::/32 2002::/16 3fff::/20)
  printf '%s\n' '-N NAVISHAI_OUTPUT' '-A NAVISHAI_OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED --ctdir REPLY -j ACCEPT'
  if [[ $family == iptables ]]; then
    printf '%s\n' '-A NAVISHAI_OUTPUT -d 127.0.0.1/32 -o lo -j ACCEPT'
    # Docker DNATs 127.0.0.11:53 to its randomly bound resolver port BEFORE
    # filter OUTPUT. Match original tuples, not a broad loopback exception.
    for protocol in tcp udp; do
      printf '%s\n' "-A NAVISHAI_OUTPUT -d 127.0.0.11/32 -o lo -p $protocol -m conntrack --ctorigdst 127.0.0.11 --ctorigdstport 53 --ctdir ORIGINAL -j ACCEPT"
    done
    printf '%s\n' "-A NAVISHAI_OUTPUT -d $postgres/32 -p tcp -m tcp --dport 5432 -j ACCEPT"
    reject=icmp-port-unreachable
    for range in "${blocked4[@]}"; do
      printf '%s\n' "-A NAVISHAI_OUTPUT -d $range -j REJECT --reject-with $reject"
    done
  else
    reject=icmp6-port-unreachable
    printf '%s\n' '-A NAVISHAI_OUTPUT -d ::1/128 -o lo -j ACCEPT'
    # Neighbour solicitation/advertisement only, not a link-local TCP/UDP grant.
    for type in 135 136; do
      printf '%s\n' "-A NAVISHAI_OUTPUT -p ipv6-icmp -m icmp6 --icmpv6-type $type -j ACCEPT"
    done
    printf '%s\n' "-A NAVISHAI_OUTPUT ! -d 2000::/3 -j REJECT --reject-with $reject"
    for range in "${blocked6[@]}"; do
      printf '%s\n' "-A NAVISHAI_OUTPUT -d $range -j REJECT --reject-with $reject"
    done
  fi
  if [[ -n ${_vps_policy_binding:-} ]]; then
    printf '%s\n' "-A NAVISHAI_OUTPUT -m comment --comment $_vps_policy_binding -j ACCEPT"
  else
    printf '%s\n' '-A NAVISHAI_OUTPUT -j ACCEPT'
  fi
}

_vps_policy_verify_family() {
  local family=$1 actual hooks
  actual=$(nsenter "--net=$_vps_policy_namespace" "$family" -w 5 -S NAVISHAI_OUTPUT) || return 1
  [[ $actual == "$(_vps_policy_rules "$family" "$_vps_policy_postgres")" ]] || {
    _vps_policy_error "changed $family policy; leave workloads stopped"; return 1;
  }
  hooks=$(nsenter "--net=$_vps_policy_namespace" "$family" -w 5 -S OUTPUT) || return 1
  local line first='' references=0
  while IFS= read -r line; do
    [[ $line == '-A OUTPUT '* ]] || continue
    [[ -n $first ]] || first=$line
    [[ $line == *'NAVISHAI_OUTPUT'* ]] && references=$((references + 1))
  done <<< "$hooks"
  [[ $first == '-A OUTPUT -j NAVISHAI_OUTPUT' && $references == 1 ]] || {
    _vps_policy_error "shadowed/duplicate $family OUTPUT hook; leave workloads stopped"; return 1;
  }
}

_vps_policy_run() {
  local action=$1 tool initial current pid inode fd family existing
  [[ $EUID == 0 ]] || { _vps_policy_error 'run as root'; return 1; }
  for tool in nsenter stat sha256sum tail iptables ip6tables iptables-restore ip6tables-restore; do
    command -v "$tool" >/dev/null || { _vps_policy_error "missing $tool"; return 1; }
  done
  declare -F vps_compose >/dev/null && declare -F vps_docker >/dev/null || return 1
  initial=$(_vps_policy_inspect) || return 1
  local -a context
  mapfile -t context <<< "$initial"
  IFS='|' read -r _ _ _ _ pid _ <<< "${context[0]}"
  inode=${context[2]}
  local _vps_policy_postgres=${context[3]} _vps_policy_namespace _vps_policy_binding
  # Bind the installed policy to container IDs/PIDs, network IDs/addresses and
  # namespace identity. A replacement must not inherit a stale green check.
  _vps_policy_binding=$(printf '%s' "$initial" | sha256sum) || return 1
  _vps_policy_binding=${_vps_policy_binding%% *}
  # Pin the exact namespace; a restarted Docker PID cannot redirect nsenter to
  # another namespace. Recheck Docker identity after the operation too.
  exec {fd}<"/proc/$pid/ns/net" || return 1
  _vps_policy_namespace="/proc/$BASHPID/fd/$fd"
  [[ $(stat -Lc '%i' "$_vps_policy_namespace") == "$inode" ]] || return 1
  # Probe BOTH families before writing either. Missing kernel IPv6 must fail.
  for family in iptables ip6tables; do
    nsenter "--net=$_vps_policy_namespace" "$family" -w 5 -S OUTPUT >/dev/null || return 1
  done
  # Refuse changed/partial existing policy. Never repair by flushing or replacing
  # a changed chain; the operator must stop workloads and recreate the holder.
  local -a missing=()
  for family in iptables ip6tables; do
    existing=$(nsenter "--net=$_vps_policy_namespace" "$family" -w 5 -S) || return 1
    if [[ $existing == *'-N NAVISHAI_OUTPUT'* ]]; then
      _vps_policy_verify_family "$family" || return 1
    else
      [[ $existing != *NAVISHAI_OUTPUT* && $action == apply ]] || {
        _vps_policy_error "missing $family policy"; return 1;
      }
      missing+=("$family")
    fi
  done
  # One missing family with one installed is a partial policy, not a fresh holder.
  [[ ${#missing[@]} != 1 ]] || { _vps_policy_error 'partial policy; recreate holder'; return 1; }
  for family in "${missing[@]}"; do
    {
      printf '%s\n' '*filter' ':NAVISHAI_OUTPUT - [0:0]'
      _vps_policy_rules "$family" "$_vps_policy_postgres" | tail -n +2
      printf '%s\n' '-I OUTPUT 1 -j NAVISHAI_OUTPUT' COMMIT
    } | nsenter "--net=$_vps_policy_namespace" "${family}-restore" --wait 5 --noflush || return 1
  done
  for family in iptables ip6tables; do
    _vps_policy_verify_family "$family" || return 1
  done
  current=$(_vps_policy_inspect) || return 1
  [[ $current == "$initial" ]] || { _vps_policy_error 'Docker identity changed during policy operation'; return 1; }
  printf 'PASS: application namespace IPv4/IPv6 OUTPUT policy %s; holder %s, namespace %s.\n' "$action" "${context[0]%%|*}" "$inode"
}

# Subshells close the pinned descriptor and keep shell options/variables local.
vps_policy_apply() ( _vps_policy_run apply; )
vps_policy_check() ( _vps_policy_run check; )
