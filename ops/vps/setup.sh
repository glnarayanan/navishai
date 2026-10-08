# Sourced by the VPS CLI. Caller supplies source, commit, answers,
# non_interactive and resume locals. No installed state changes until consent.
vps_setup_field_valid() {
  local key="$1" value="$2" label
  local -a labels
  [[ -n $value && ${#value} -le 1024 && $value != *[[:cntrl:]]* ]] || return 1
  case "$key" in
    host)
      NAVISHAI_APP_HOST="$value" NAVISHAI_ACME_EMAIL=a@example.com vps_identity >/dev/null 2>&1 || return 1
      [[ ${#value} -le 253 && ! $value =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
      IFS=. read -r -a labels <<< "$value"
      for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
      done ;;
    acme_email|owner_email|smtp_from) [[ $value =~ ^[a-zA-Z0-9_.+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]+$ && ${#value} -le 254 ]] ;;
    smtp_port) [[ $value =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$value <= 65535)) ;;
    smtp_server) [[ $value =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && $value != *..* ]] ;;
    smtp_user|smtp_password) [[ $value != *[\'\\]* ]] ;;
    owner_password|owner_password_confirmation)
      [[ ${#value} -ge 12 ]] || return 1
      local LC_ALL=C
      [[ ${#value} -le 72 ]] ;;
    organization_name|workspace_name) [[ ${#value} -le 100 && $value == *[![:space:]]* ]] ;;
    organization_slug|workspace_slug) [[ ${#value} -le 63 && $value =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] ;;
    *) return 1 ;;
  esac
}

vps_setup() (
  # Never trace answers, including when a caller enabled bash -x.
  set +x
  umask 077
  local -a fields=(host acme_email smtp_server smtp_port smtp_user smtp_password smtp_from owner_email owner_password owner_password_confirmation organization_name organization_slug workspace_name workspace_slug)
  local -A values=()
  local key value consent temporary= envfile= host= email= output= listen_address="${listen_address:-}" account status
  trap '[[ -z $temporary ]] || rm -rf -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  [[ $EUID == 0 ]] || { vps_die 'Guided setup requires root.'; return 1; }
  if [[ ${resume:-false} == true ]]; then
    vps_load || return 1
    [[ -z ${commit:-} || $commit == "$(cat "$VPS_RELEASE/SOURCE_COMMIT")" ]] || { vps_die 'Resume requires the installed commit; use a backed-up upgrade to change releases.'; return 1; }
    # Resume builds this owned archive, never a source checkout. Recheck under
    # the mutation lock after consent, in case another operation changed it.
    commit="$(cat "$VPS_RELEASE/SOURCE_COMMIT")" || return 1
    [[ -z $listen_address || $listen_address == "${NAVISHAI_PUBLIC_LISTEN_ADDRESS:-auto}" ]] || { vps_die 'Resume retains ingress; change deliberate settings through a backed-up upgrade.'; return 1; }
    listen_address="${NAVISHAI_PUBLIC_LISTEN_ADDRESS:-auto}"
    fields=(owner_email owner_password owner_password_confirmation organization_name organization_slug workspace_name workspace_slug)
    printf 'Resume retains installed domain/SMTP/secrets; only unfinished account details need entry.\n'
  fi
  listen_address="${listen_address:-auto}"
  vps_resolve_ingress "$listen_address" || return 1
  if [[ -n ${answers:-} ]]; then
    [[ ${non_interactive:-false} == true ]] || { vps_die '--answers requires --non-interactive.'; return 1; }
    answers="$(realpath -ms -- "$answers")" || return 1
    vps_directory "$(dirname -- "$answers")" && vps_private "$answers" || return 1
    [[ $(stat -c %a -- "$answers") == 600 && $(stat -c %s -- "$answers") -le 32768 ]] || { vps_die 'Answers must be a bounded 0600 file.'; return 1; }
    # --stream preserves duplicate paths, unlike an ordinary object parse.
    jq --stream -n -e '[inputs | select(length == 2) | .[0]] as $p | ($p | length) == ($p | unique | length)' "$answers" >/dev/null 2>&1 &&
      jq -s -e 'length == 1 and (.[0] | type == "object" and (keys == ["acme_email","host","organization_name","organization_slug","owner_email","owner_password","owner_password_confirmation","smtp_from","smtp_password","smtp_port","smtp_server","smtp_user","workspace_name","workspace_slug"]) and all(.[]; type == "string" and (length > 0) and (test("[\u0000-\u001f\u007f]") | not)))' "$answers" >/dev/null 2>&1 || { vps_die 'Invalid answers: require exactly the documented string fields, without duplicates.'; return 1; }
    for key in "${fields[@]}"; do
      value="$(jq -r --arg key "$key" '.[$key]' "$answers")" || return 1
      vps_setup_field_valid "$key" "$value" || { vps_die "Invalid answer for $key (value withheld)."; return 1; }
      values[$key]="$value"
    done
  else
    [[ ${non_interactive:-false} != true && -t 0 && -t 1 ]] || { vps_die 'Use a terminal, or --non-interactive --answers with a protected JSON file.'; return 1; }
    printf 'Guided setup; automatic ingress (no IP required). Ctrl-C or EOF cancels.\n'
    printf 'SMTP requires authenticated STARTTLS with a trusted certificate (usually port 587, no leading zeroes).\n'
    for key in "${fields[@]}"; do
      while :; do
        case "$key" in
          *password*) IFS= read -r -s -p "$key: " value || return 1; printf '\n' ;;
          *) IFS= read -r -p "$key: " value || return 1 ;;
        esac
        if vps_setup_field_valid "$key" "$value"; then
          if [[ $key != owner_password_confirmation || $value == "${values[owner_password]}" ]]; then break; fi
        fi
        printf 'Invalid %s; please correct (value withheld).\n' "$key"
      done
      values[$key]="$value"
    done
  fi
  [[ ${values[owner_password]} == "${values[owner_password_confirmation]}" ]] || { vps_die 'Owner passwords do not match.'; return 1; }
  printf 'Review nonsecret choices (SMTP user/password and Owner passwords withheld):\n'
  printf '  ingress: %s (validated host address %s; no host IP saved in auto mode)\n' "$listen_address" "$VPS_PUBLIC_LISTEN_ADDRESS"
  for key in "${fields[@]}"; do
    case "$key" in *password*|smtp_user) continue ;; esac
    printf '  %s: %s\n' "$key" "${values[$key]}"
  done
  if [[ ${resume:-false} == true ]]; then printf 'Resume: existing configuration and secrets will be retained.\n'; fi
  if [[ ${non_interactive:-false} != true ]]; then
    printf 'Apply these choices? Type yes to continue: '
    IFS= read -r consent || return 1
    [[ $consent == yes ]] || { vps_die 'Cancelled; installed state unchanged.'; return 1; }
  fi
  if [[ ${resume:-false} == true ]]; then
    vps_resume || { vps_die 'Resume failed. Correct the reported prerequisite and retry install --resume; do not delete installed state.'; return 1; }
  else
    temporary="$(mktemp -d /tmp/navishai-setup.XXXXXXXX)" || return 1
    vps_directory "$temporary" || return 1
    host="${values[host]}"; email="${values[acme_email]}"; output="$temporary/generated-env"
    vps_init_env >/dev/null || return 1
    # Replace placeholders without interpolating secrets into process arguments.
    sed '/^NAVISHAI_SYSTEM_SMTP_/d' "$output" > "$temporary/env" || return 1
    for key in server port user password from; do
      case "$key" in server) value=ADDRESS ;; user) value=USER_NAME ;; *) value="${key^^}" ;; esac
      printf "NAVISHAI_SYSTEM_SMTP_%s='%s'\n" "$value" "${values[smtp_$key]}" >> "$temporary/env"
    done
    envfile="$temporary/env"
    chmod 600 -- "$envfile" || return 1
    vps_install || { vps_die 'Install failed. Preserve installed state, correct the reported prerequisite, then retry install --resume and re-enter account details.'; return 1; }
  fi
  # Startup took the released lock; account setup must hold it again.
  vps_load && vps_lock || return 1
  account="$(for key in owner_email owner_password owner_password_confirmation organization_name organization_slug workspace_name workspace_slug; do printf '%s\n' "${values[$key]}"; done | jq -Rn '[inputs] | {email_address:.[0],password:.[1],password_confirmation:.[2],organization_name:.[3],organization_slug:.[4],workspace_name:.[5],workspace_slug:.[6]}')" || return 1
  status=0
  # This is a runtime write after gated startup, not one-off maintenance.
  printf '%s\n' "$account" | vps_compose exec -T web bin/rails runner ops/vps/bootstrap_owner.rb || status=$?
  unset account values value
  (( status == 0 )) || { vps_die 'Owner setup did not complete. Correct the named cause, then run sudo navishai-reset install --resume. Never delete installed data.'; return "$status"; }
)

vps_renew_bootstrap() (
  set +x
  umask 077
  vps_stop && vps_guard || return 1
  vps_compose run --pull never --rm --no-deps web bin/rails navishai:first_owner:renewable || return 1
  local token expiry
  token="$(openssl rand -hex 48)" && expiry="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)" || return 1
  (set -o noclobber; { sed '/^NAVISHAI_BOOTSTRAP_TOKEN\(_EXPIRES_AT\)\?=/d' "$VPS_CONFIG/env" && printf "NAVISHAI_BOOTSTRAP_TOKEN='%s'\nNAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT='%s'\n" "$token" "$expiry"; } > "$VPS_CONFIG/env.new") &&
    chmod 600 -- "$VPS_CONFIG/env.new" && mv -f -- "$VPS_CONFIG/env.new" "$VPS_CONFIG/env" || return 1
  unset token
  printf 'Protected bootstrap token renewed for two hours; writers remain stopped. Run sudo navishai-reset install --resume.\n'
)
