# Bootstrap only an empty destination from an explicitly approved portable backup.
vps_recover() (
  set +x
  umask 077
  local VPS_RECOVERY_WORK= VPS_RECOVERY_DESTINATION=true
  local desired="${listen_address:-auto}" sha
  trap '[[ -z $VPS_RECOVERY_WORK ]] || rm -rf -- "$VPS_RECOVERY_WORK"' EXIT
  [[ -n $from && $confirmation =~ ^[0-9a-f]{64}$ && $(sha256sum -- "$from/CHECKSUMS" | cut -d' ' -f1) == "$confirmation" ]] || { vps_die 'Inspect backup; recover requires its CHECKSUMS SHA256.'; return 1; }
  if [[ ${resume:-false} == true ]]; then
    vps_load no-env && vps_lock || return 1
    [[ $(jq -r .phase "$VPS_STATE/install.json") == recovering ]] || { vps_die 'Recovery resume requires an unfinished destination receipt; never adopt an existing installation.'; return 1; }
    vps_rename_cli && vps_cleanup_plan >/dev/null || return 1
  else vps_fresh_check || return 1; fi
  vps_resolve_ingress "$desired" || return 1
  VPS_RECOVERY_WORK="$(mktemp -d /tmp/navishai-destination.XXXXXXXX)" || return 1
  source "${BASH_SOURCE[0]%/*}/recovery.sh" || return 1
  vps_recovery_backup_check "$from" || { vps_die 'Destination backup validation failed; no installed data changed.'; return 1; }
  sha="$VPS_RECOVERY_SHA"
  mkdir -m 700 "$VPS_RECOVERY_WORK/release" "$VPS_RECOVERY_WORK/config" "$VPS_RECOVERY_WORK/state" || return 1
  local key
  for key in release config state; do tar --numeric-owner --same-owner --same-permissions -xf "$from/$key.tar" -C "$VPS_RECOVERY_WORK/$key" || return 1; done
  [[ $(cat "$VPS_RECOVERY_WORK/release/SOURCE_COMMIT") == "$sha" ]] &&
    grep -Fq '${VPS_PUBLIC_LISTEN_ADDRESS:?' "$VPS_RECOVERY_WORK/release/ops/vps/compose.yaml" || { vps_die 'Backup predates portable ingress. Upgrade the source installation before migration; do not edit archived code.'; return 1; }
  jq -e --arg sha "$sha" '.schema == 1 and .project == "navishai-reset" and .commit == $sha and (.prefix | endswith("/opt/navishai-reset")) and (.config | endswith("/etc/navishai-reset")) and (.state | endswith("/var/lib/navishai-reset"))' "$VPS_RECOVERY_WORK/state/install.json" >/dev/null || return 1
  if [[ ${resume:-false} == true ]]; then
    [[ $sha == "$(cat "$VPS_RELEASE/SOURCE_COMMIT")" ]] || { vps_die 'Resume requires the same reviewed destination release.'; return 1; }
  else
    mkdir -p -m 700 -- "$VPS_PREFIX/releases" "$VPS_CONFIG" "$VPS_STATE" || return 1
    vps_directory "$VPS_PREFIX" && vps_directory "$VPS_CONFIG" && vps_directory "$VPS_STATE" || return 1
    vps_lock || return 1
    mv -T -- "$VPS_RECOVERY_WORK/release" "$VPS_PREFIX/releases/$sha" &&
      install -m 600 -- "$VPS_RECOVERY_WORK/config/env" "$VPS_CONFIG/env" &&
      vps_switch "$sha" recovering && vps_write_ingress "$desired" && vps_load_env || return 1
  fi
  # Restore recreates only local resource identities; never starts web/jobs/proxy.
  listen_address="$desired"
  vps_restore "$from" && vps_load && vps_units && vps_receipt "$sha" restored || { vps_stop; vps_die 'Destination recovery failed; preserve stopped state and retry recover --resume with the retained backup and consent.'; return 1; }
  printf 'Destination data/secrets restored; writers stopped. Update DNS for this host, then start navishai-reset.service and its check timer. Gated startup validates TLS and both policy families.\n'
)
