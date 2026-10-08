# Sourced by bin/navishai-vps; no implicit action when sourced by tests.
source "${BASH_SOURCE[0]%/*}/ingress.sh"
source "${BASH_SOURCE[0]%/*}/setup.sh"
source "${BASH_SOURCE[0]%/*}/destination.sh"
vps_die() { printf 'navishai-vps: %s\n' "$*" >&2; return 1; }
vps_help() {
  cat <<'HELP'
Usage: sudo navishai [--root /] COMMAND [options]
  (before install, or from a source checkout: sudo bin/navishai-vps ...)
  upgrade [--yes]
    One step: fetch latest main into /root/navishai-source, stop if already on it,
    show new commits and confirm, back up to /root/navishai-backups, upgrade, verify.
  install --source REVIEWED_GIT_CHECKOUT --commit FULL_SHA
    Guided setup by default; automation: --non-interactive --answers PRIVATE_JSON
    Advanced prebuilt configuration: --env PRIVATE_FILE
  install --resume [--commit FULL_INSTALLED_SHA]
    Guided resume uses the protected installed release; no source checkout needed.
  init-env --host DNS_NAME --acme-email EMAIL --output NEW_PRIVATE_FILE [--public-listen-address IPV4|auto]
  upgrade [--source GIT_CHECKOUT] [--commit FULL_SHA] [--backup NEW_DIRECTORY] [--public-listen-address IPV4|auto]
    A pinned --commit skips the fetch and the confirmation.
  recover --from BACKUP_DIRECTORY --confirm-restore BACKUP_SHA256 [--resume] [--public-listen-address IPV4|auto]
  backup --output NEW_DIRECTORY
  restore --from BACKUP_DIRECTORY --confirm-restore BACKUP_SHA256
  start | stop | check | status | doctor | renew-bootstrap
  cleanup [--apply --confirm-destroy PLAN_SHA256]

Install builds only a Git archive, never local edits. Guided setup collects SMTP.
Advanced init-env templates still need SMTP fields before --env installation.
Requires root, Linux/systemd, local Docker + Compose >=2.39.4, Git, jq, curl, ip, ss,
OpenSSL, tar, flock, nsenter, iptables/ip6tables and their save/restore tools.
No package installer, old-data conversion, broad prune or host firewall mutation.
Cleanup previews exact owned resources; apply destroys them and all reset data.
Backup/upgrade stop writers. Failed backup/restore/upgrade remains stopped.
Restore refuses unknown owners, unsafe archives and changed backup checksums.
Public DNS/80/443, working SMTP and host storage policy are operator prerequisites.
HELP
}
vps_paths() {
  local root="${1:-/}"
  [[ $root =~ ^/[a-zA-Z0-9_./-]*$ && $root != *'/../'* && $root != */.. && ! -L $root ]] || { vps_die 'Invalid managed root.'; return 1; }
  VPS_ROOT="$(realpath -e -- "$root")" || return 1
  vps_directory "$VPS_ROOT" || return 1
  VPS_PREFIX="${VPS_ROOT%/}/opt/navishai-reset"
  VPS_CONFIG="${VPS_ROOT%/}/etc/navishai-reset"
  VPS_STATE="${VPS_ROOT%/}/var/lib/navishai-reset"
  VPS_CLI="${VPS_ROOT%/}/usr/local/bin/navishai"
  # Older installs linked this name; vps_rename_cli moves them to VPS_CLI once.
  VPS_LEGACY_CLI="${VPS_ROOT%/}/usr/local/bin/navishai-reset"
  VPS_SOURCE="${VPS_ROOT%/}/root/navishai-source"
  VPS_BACKUPS="${VPS_ROOT%/}/root/navishai-backups"
  VPS_REPOSITORY=https://github.com/glnarayanan/navishai.git
  VPS_UNITS="${VPS_ROOT%/}/etc/systemd/system"
  VPS_PROJECT=navishai-reset
  export VPS_PROJECT
}
vps_private() {
  local file="$1" mode
  [[ -f $file && ! -L $file && $(stat -c %u -- "$file") == 0 && $(stat -c %h -- "$file") == 1 ]] || { vps_die "Not a root-owned single-link regular file: $file"; return 1; }
  mode=$((8#$(stat -c %a -- "$file")))
  (( (mode & 0077) == 0 )) || { vps_die "Private file is readable by another user: $file"; return 1; }
}
vps_directory() {
  local path="$1" current="$1" mode
  [[ -d $path && ! -L $path && $(realpath -e -- "$path") == "$path" ]] || { vps_die "Unsafe directory: $path"; return 1; }
  while [[ $current != / ]]; do
    mode=$((8#$(stat -c %a -- "$current")))
    # A root-owned child in a root-owned sticky /tmp cannot be renamed by peers.
    [[ $(stat -c %u -- "$current") == 0 ]] && { (( (mode & 0022) == 0 )) || { [[ $current != "$path" ]] && (( (mode & 01000) != 0 )); }; } || { vps_die "Directory ancestry is not root-controlled: $current"; return 1; }
    current="$(dirname -- "$current")"
  done
}
vps_identity() {
  [[ ${NAVISHAI_APP_HOST:-} =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && ${NAVISHAI_APP_HOST:-} == *.* && ${NAVISHAI_APP_HOST:-} != *..* ]] || { vps_die 'Set a plain lower-case public DNS hostname.'; return 1; }
  [[ ${NAVISHAI_ACME_EMAIL:-} =~ ^[a-zA-Z0-9_.+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]+$ ]] || { vps_die 'Set an ACME contact email.'; return 1; }
}
vps_load_env() {
  local line key value
  local -a keys=()
  # Delete stale shell values: they take precedence over Compose --env-file.
  while IFS= read -r key; do unset "$key"; done < <(compgen -v NAVISHAI_)
  vps_directory "$VPS_CONFIG" && vps_private "$VPS_CONFIG/env" || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^(NAVISHAI_[A-Z_]+)=(.*)$ ]] || { vps_die 'Expected NAME=value literal dotenv (no shell statements).'; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$key" in
      NAVISHAI_APP_HOST|NAVISHAI_PUBLIC_LISTEN_ADDRESS|NAVISHAI_ACME_EMAIL|NAVISHAI_DATABASE_PASSWORD|NAVISHAI_POSTGRES_PASSWORD|NAVISHAI_PREPARE_PASSWORD|NAVISHAI_SECRET_KEY_BASE|NAVISHAI_BOOTSTRAP_TOKEN|NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT|NAVISHAI_SYSTEM_SMTP_ADDRESS|NAVISHAI_SYSTEM_SMTP_PORT|NAVISHAI_SYSTEM_SMTP_USER_NAME|NAVISHAI_SYSTEM_SMTP_PASSWORD|NAVISHAI_SYSTEM_SMTP_FROM|NAVISHAI_OIDC_ISSUER|NAVISHAI_OIDC_CLIENT_ID|NAVISHAI_OIDC_CLIENT_SECRET|NAVISHAI_EVALUATION_ENDPOINTS|NAVISHAI_SCENARIO_ENDPOINTS|NAVISHAI_CORPUS_ENDPOINTS|NAVISHAI_MATCHING_ENDPOINTS|NAVISHAI_IMPACT_ENDPOINTS|NAVISHAI_TRACE_DISCOVERY_ENDPOINTS) ;;
      *) vps_die "Unsupported environment key: $key"; return 1 ;;
    esac
    [[ " ${keys[*]} " != *" $key "* ]] || { vps_die "Duplicate key: $key"; return 1; }
    keys+=("$key")
    if [[ $value == \'*\' ]]; then value="${value:1:${#value}-2}";
    else [[ $value != *[\ \"\'\$\`\\]* ]] || { vps_die 'Quote literal values with single quotes, without embedded quotes or backslashes.'; return 1; }; fi
    [[ $value != *[\'\\]* && $value != *$'\r'* ]] || { vps_die 'Unsupported escape or quote in literal env value.'; return 1; }
    printf -v "$key" '%s' "$value"; export "$key"
  done < "$VPS_CONFIG/env"
  vps_identity || return 1
  [[ ${NAVISHAI_PUBLIC_LISTEN_ADDRESS:-auto} == auto ]] || vps_public_listen_address "$NAVISHAI_PUBLIC_LISTEN_ADDRESS" || { vps_die 'Invalid desired public listen address.'; return 1; }
  for key in NAVISHAI_DATABASE_PASSWORD NAVISHAI_POSTGRES_PASSWORD NAVISHAI_PREPARE_PASSWORD NAVISHAI_SECRET_KEY_BASE; do
    [[ ${!key:-} =~ ^[a-zA-Z0-9_-]{32,}$ ]] || { vps_die "Use at least 32 random URL-safe characters for $key."; return 1; }
  done
  [[ $NAVISHAI_DATABASE_PASSWORD != "$NAVISHAI_POSTGRES_PASSWORD" && $NAVISHAI_DATABASE_PASSWORD != "$NAVISHAI_PREPARE_PASSWORD" && $NAVISHAI_POSTGRES_PASSWORD != "$NAVISHAI_PREPARE_PASSWORD" ]] || { vps_die 'All database passwords must differ.'; return 1; }
  for key in NAVISHAI_SYSTEM_SMTP_ADDRESS NAVISHAI_SYSTEM_SMTP_PORT NAVISHAI_SYSTEM_SMTP_USER_NAME NAVISHAI_SYSTEM_SMTP_PASSWORD NAVISHAI_SYSTEM_SMTP_FROM; do
    [[ -n ${!key:-} ]] || { vps_die "Configure required production mail: $key"; return 1; }
  done
  [[ $NAVISHAI_SYSTEM_SMTP_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$NAVISHAI_SYSTEM_SMTP_PORT > 0 && 10#$NAVISHAI_SYSTEM_SMTP_PORT <= 65535)) || { vps_die 'Invalid SMTP port.'; return 1; }
  for key in NAVISHAI_EVALUATION_ENDPOINTS NAVISHAI_SCENARIO_ENDPOINTS NAVISHAI_CORPUS_ENDPOINTS NAVISHAI_MATCHING_ENDPOINTS NAVISHAI_IMPACT_ENDPOINTS NAVISHAI_TRACE_DISCOVERY_ENDPOINTS; do
    [[ -n ${!key:-} ]] || { printf -v "$key" '[]'; export "$key"; }
    jq -e 'type == "array"' <<<"${!key}" >/dev/null || { vps_die "Expected JSON array for $key."; return 1; }
  done
}
vps_init_env() {
  [[ -n $host && -n $email && -n $output && ! -e $output && ! -L $output ]] || { vps_die 'init-env needs --host, --acme-email and a new --output file.'; return 1; }
  NAVISHAI_APP_HOST="$host" NAVISHAI_ACME_EMAIL="$email" vps_identity || return 1
  vps_resolve_ingress "${listen_address:-auto}" || return 1
  vps_directory "$(dirname -- "$(realpath -m -- "$output")")" || return 1
  (set -o noclobber
    {
      printf '# Literal dotenv; single quotes, no embedded quotes/backslashes. Fill SMTP before install.\n'
      printf "NAVISHAI_APP_HOST='%s'\nNAVISHAI_ACME_EMAIL='%s'\n" "$host" "$email"
      printf "NAVISHAI_PUBLIC_LISTEN_ADDRESS='%s'\n" "${listen_address:-auto}"
      local key
      for key in DATABASE_PASSWORD POSTGRES_PASSWORD PREPARE_PASSWORD SECRET_KEY_BASE BOOTSTRAP_TOKEN; do printf "NAVISHAI_%s='%s'\n" "$key" "$(openssl rand -hex 48)"; done
      printf "NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT='%s'\n" "$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
      for key in ADDRESS PORT USER_NAME PASSWORD FROM; do printf "NAVISHAI_SYSTEM_SMTP_%s=''\n" "$key"; done
      for key in EVALUATION SCENARIO CORPUS MATCHING IMPACT TRACE_DISCOVERY; do printf "NAVISHAI_%s_ENDPOINTS='[]'\n" "$key"; done
    } > "$output"
  ) || return 1
  chmod 600 -- "$output"
  printf 'Private template written. Fill SMTP and install within bootstrap expiry; no secret printed.\n'
}
vps_docker() { docker "$@"; }
vps_doctor() {
  [[ $EUID == 0 && $(uname -s) == Linux ]] || { vps_die 'Requires root on Linux.'; return 1; }
  local tool version
  for tool in docker git jq curl getent awk openssl tar flock nsenter ip iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ss findmnt systemctl realpath sha256sum; do
    command -v "$tool" >/dev/null || { vps_die "Missing prerequisite: $tool"; return 1; }
  done
  [[ $(vps_docker context inspect --format '{{.Endpoints.docker.Host}}') == unix:///* ]] || { vps_die 'Only the local Unix Docker context is supported.'; return 1; }
  vps_docker info --format '{{.ID}}' >/dev/null || return 1
  version="$(vps_docker compose version --short)" || return 1
  [[ $(printf '%s\n' 2.39.4 "${version#v}" | sort -V | head -1) == 2.39.4 ]] || { vps_die 'Compose >=2.39.4 required for safe sequence overrides.'; return 1; }
  [[ $VPS_ROOT != / || -d /run/systemd/system ]] || { vps_die 'Persistent startup requires systemd.'; return 1; }
}
vps_compose() {
  vps_resolve_ingress || return 1
  local -a files=(--file "$VPS_RELEASE/compose.yaml" --file "$VPS_RELEASE/ops/vps/compose.yaml")
  if [[ -e $VPS_STATE/recovery-images.yaml || -L $VPS_STATE/recovery-images.yaml ]]; then
    vps_private "$VPS_STATE/recovery-images.yaml" || return 1
    jq -e 'keys == ["services"] and (.services | type == "object" and (keys == ["app-net","jobs","postgres","proxy","web"]) and all(.[]; keys == ["image"] and (.image | test("^sha256:[0-9a-f]{64}$"))))' "$VPS_STATE/recovery-images.yaml" >/dev/null || { vps_die 'Invalid recovery image overlay.'; return 1; }
    files+=(--file "$VPS_STATE/recovery-images.yaml")
  fi
  export VPS_IMAGE="navishai-reset:$(cat "$VPS_RELEASE/SOURCE_COMMIT")"
  vps_docker compose --project-name "$VPS_PROJECT" --project-directory "$VPS_RELEASE" --env-file "$VPS_CONFIG/env" "${files[@]}" "$@"
}
vps_pull_pins() {
  local service reference inspected
  for service in postgres proxy; do
    reference="$(vps_compose config --format json | jq -er --arg service "$service" '.services[$service].image')" || return 1
    [[ $reference =~ ^[a-zA-Z0-9][a-zA-Z0-9_./:-]*@sha256:[0-9a-f]{64}$ ]] || { vps_die "Unpinned image: $service"; return 1; }
    if ! inspected="$(vps_docker image inspect --format '{{.Id}}' "$reference" 2>&1)"; then
      # Compose 2.39.4's missing policy still pulls cached name:tag@digest refs.
      # Only a real NotFound permits a pull; daemon/API failures stop the operation.
      [[ $inspected == *"No such image: $reference" ]] || { vps_die "Cannot inspect pinned image: $service"; return 1; }
      vps_docker pull "$reference" || return 1
      inspected="$(vps_docker image inspect --format '{{.Id}}' "$reference")" || return 1
    fi
    [[ $inspected =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  done
}
vps_load() {
  vps_directory "$VPS_PREFIX" && vps_directory "$VPS_CONFIG" && vps_directory "$VPS_STATE" || return 1
  vps_private "$VPS_STATE/install.json" || return 1
  jq -e --arg prefix "$VPS_PREFIX" --arg config "$VPS_CONFIG" --arg state "$VPS_STATE" '.schema == 1 and .project == "navishai-reset" and .prefix == $prefix and .config == $config and .state == $state and (.commit | test("^[0-9a-f]{40}$"))' "$VPS_STATE/install.json" >/dev/null || { vps_die 'Install receipt mismatch.'; return 1; }
  VPS_RELEASE="$(realpath -e -- "$VPS_PREFIX/current")" || return 1
  [[ $VPS_RELEASE == "$VPS_PREFIX/releases/$(jq -r .commit "$VPS_STATE/install.json")" && ! -L $VPS_RELEASE ]] || { vps_die 'Current release mismatch.'; return 1; }
  vps_directory "$VPS_RELEASE" || return 1
  [[ $(cat "$VPS_RELEASE/SOURCE_COMMIT") == "$(jq -r .commit "$VPS_STATE/install.json")" ]] || return 1
  [[ ${1:-env} != cleanup ]] || return 0
  [[ ${1:-env} == no-env ]] || vps_load_env || return 1
  source "$VPS_RELEASE/ops/vps/policy.sh" || return 1
  source "$VPS_RELEASE/ops/vps/recovery.sh" || return 1
}
vps_lock() {
  [[ ! -L $VPS_STATE/install.lock ]] || return 1
  exec {VPS_LOCK}>"$VPS_STATE/install.lock"
  flock -n -x "$VPS_LOCK" || { vps_die 'Another reset operation is active.'; return 1; }
}
vps_receipt() {
  local sha="$1" phase="$2"
  jq -n --arg prefix "$VPS_PREFIX" --arg config "$VPS_CONFIG" --arg state "$VPS_STATE" --arg sha "$sha" --arg phase "$phase" '{schema:1,project:"navishai-reset",prefix:$prefix,config:$config,state:$state,commit:$sha,phase:$phase}' > "$VPS_STATE/install.json.new" &&
    chmod 600 -- "$VPS_STATE/install.json.new" &&
    mv -f -- "$VPS_STATE/install.json.new" "$VPS_STATE/install.json"
}
vps_archive() {
  local source="$1" sha="$2" release="$VPS_PREFIX/releases/$2"
  [[ $sha =~ ^[0-9a-f]{40}$ && -d $source ]] || { vps_die 'Use reviewed local Git source and a full commit SHA.'; return 1; }
  [[ $(git -c safe.directory="$source" -C "$source" rev-parse --verify "$sha^{commit}") == "$sha" ]] || return 1
  [[ ! -e $release ]] || { vps_die 'Release directory already exists; never overwrite code.'; return 1; }
  if git -c safe.directory="$source" -C "$source" ls-tree -r "$sha" | grep -E '^(120000|160000) ' >/dev/null; then vps_die 'Release links/submodules are not supported.'; return 1; fi
  mkdir -p -- "$VPS_PREFIX/releases" || return 1
  mkdir -m 755 -- "$release" || return 1
  git -c safe.directory="$source" -C "$source" archive "$sha" | tar -x -C "$release" || return 1
  printf '%s\n' "$sha" > "$release/SOURCE_COMMIT" || return 1
  # Root tar preserves Git's 0664/0775 headers despite umask; recovery requires
  # code to be readable by containers but writable only by its root owner.
  chmod -R a+rX,go-w -- "$release" || return 1
  local file
  for file in bin/navishai-vps ops/vps/cli.sh ops/vps/compose.yaml ops/vps/policy.sh ops/vps/recovery.sh ops/vps/initialize_roles.sh; do
    [[ -f $release/$file && ! -L $release/$file ]] || { vps_die "Incomplete VPS release: $file"; return 1; }
  done
  printf '%s\n' "$release"
}
vps_switch() {
  local sha="$1" phase="$2"
  ln -s "releases/$sha" "$VPS_PREFIX/current.new" && mv -Tf -- "$VPS_PREFIX/current.new" "$VPS_PREFIX/current" || return 1
  VPS_RELEASE="$VPS_PREFIX/releases/$sha"
  vps_receipt "$sha" "$phase"
}
vps_container_inventory() {
  local ids
  ids="$(vps_docker ps -aq)" || return 1
  [[ -n $ids ]] || { printf '[]\n'; return; }
  local -a array
  mapfile -t array <<< "$ids"
  vps_docker inspect --type container --format '{"id":{{json .Id}},"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}}}' "${array[@]}" | jq -es .
}
vps_owned_containers() {
  local inventory="$1" selected files first second third extra release service
  selected="$(jq -c --arg p "$VPS_PROJECT" '[.[] | select(.labels["com.docker.compose.project"] == $p)]' <<< "$inventory")" || return 1
  jq -e 'all(.[]; .labels["com.navishai.owner"] == "navishai-reset" and (.id | test("^[0-9a-f]{64}$")) and (.labels["com.docker.compose.service"] as $s | ["postgres","app-net","web","jobs","proxy"] | index($s) != null))' <<< "$selected" >/dev/null || { vps_die 'Unowned or unexpected project container.'; return 1; }
  while IFS= read -r files; do
    IFS=, read -r first second third extra <<< "$files"
    release="${first%/compose.yaml}"
    [[ $release == "$VPS_PREFIX/releases/"* && ${release##*/} =~ ^[0-9a-f]{40}$ && $first == "$release/compose.yaml" && $second == "$release/ops/vps/compose.yaml" && ( -z $third || $third == "$VPS_STATE/recovery-images.yaml" ) && -z $extra ]] || { vps_die 'Container uses foreign Compose files.'; return 1; }
  done < <(jq -r '.[].labels["com.docker.compose.project.config_files"]' <<< "$selected")
  printf '%s\n' "$selected"
}
vps_stop() {
  # Stops even when private config needs repair; never evaluates Compose/env first.
  local inventory owned ids
  inventory="$(vps_container_inventory)" && owned="$(vps_owned_containers "$inventory")" || return 1
  ids="$(jq -r '.[] | select(.labels["com.docker.compose.service"] != "postgres" and .labels["com.docker.compose.service"] != "app-net") | .id' <<< "$owned")" || return 1
  [[ -n $ids ]] || return 0
  local -a array
  mapfile -t array <<< "$ids"
  vps_docker stop --time 60 "${array[@]}"
}
vps_guard() {
  vps_policy_apply && vps_policy_check || { vps_stop >&2; vps_die 'Policy failed; writers must remain stopped.'; return 1; }
}
vps_prepare() {
  # Compose keeps the extra secret out of persistent runtime environments.
  vps_compose run --pull never --rm --no-deps -e NAVISHAI_PREPARE_PASSWORD web sh -ec '
    export NAVISHAI_DATABASE_USERNAME=navishai_setup
    export NAVISHAI_DATABASE_PASSWORD="$NAVISHAI_PREPARE_PASSWORD"
    unset NAVISHAI_PREPARE_PASSWORD
    exec bin/rails db:prepare db:grant_runtime
  '
}
vps_validate() {
  vps_compose run --pull never --rm --no-deps web bin/rails zeitwerk:check &&
    vps_compose run --pull never --rm --no-deps web bin/rails db:abort_if_pending_migrations &&
    vps_compose run --pull never --rm --no-deps web bin/rails runner 'abort "Elevated runtime" if ActiveRecord::Base.connection.select_value("SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname = current_user"); ActiveRecord::Base.configurations.configs_for(env_name: "production").each { |c| ActiveRecord::Base.establish_connection(c); abort "Wrong runtime" unless ActiveRecord::Base.connection.select_value("SELECT current_user") == "navishai"; ActiveRecord::Base.connection.execute("SELECT 1") }'
}
vps_runtime_check() {
  local holder id service metadata
  holder="$(vps_compose ps --all -q app-net)" || return 1
  [[ $holder =~ ^[0-9a-f]{64}$ ]] || return 1
  for service in web jobs; do
    id="$(vps_compose ps --all -q "$service")" || return 1
    [[ $id =~ ^[0-9a-f]{64}$ ]] || return 1
    metadata="$(vps_docker inspect --type container --format '{"user":{{json .Config.User}},"labels":{{json .Config.Labels}},"env":{{json .Config.Env}},"host":{{json .HostConfig}}}' "$id")" || return 1
    jq -e --arg holder "$holder" --arg service "$service" '.user == "1000:1000" and .labels["com.navishai.owner"] == "navishai-reset" and .labels["com.docker.compose.project"] == "navishai-reset" and .labels["com.docker.compose.service"] == $service and .host.NetworkMode == ("container:" + $holder) and .host.Privileged == false and .host.RestartPolicy.Name == "no" and .host.CapDrop == ["ALL"] and ((.host.CapAdd // []) | length == 0) and (.host.SecurityOpt == ["no-new-privileges:true"] or .host.SecurityOpt == ["no-new-privileges"]) and all(.env[]; (startswith("NAVISHAI_PREPARE_PASSWORD=") or startswith("NAVISHAI_POSTGRES_PASSWORD=") or startswith("POSTGRES_PASSWORD=") | not))' <<< "$metadata" >/dev/null || { vps_die "Unsafe runtime namespace/privileges/credentials: $service"; return 1; }
  done
}
vps_https() {
  curl --noproxy '*' --fail --silent --max-time 3 --resolve "$NAVISHAI_APP_HOST:443:127.0.0.1" "https://$NAVISHAI_APP_HOST/up" >/dev/null
}
vps_start() {
  vps_stop || return 1
  vps_ingress_check || return 1
  vps_dns_check || return 1
  vps_compose up -d --pull never --no-build --no-deps --wait postgres || return 1
  # Fresh namespace avoids stale/partial rules after replacement or interrupted apply.
  vps_compose up -d --pull never --no-build --no-deps --force-recreate --wait app-net || return 1
  vps_guard || return 1
  vps_validate || return 1
  # Verify attachment BEFORE a runtime process can send, not after `up -d`.
  vps_compose up --no-start --pull never --no-build --no-deps --force-recreate web jobs && vps_runtime_check && vps_policy_check || return 1
  VPS_WRITERS_STARTED=true
  vps_compose start web jobs || { vps_stop; return 1; }
  local attempt ready=false
  for attempt in {1..60}; do
    if curl --fail --silent --max-time 2 --header "Host: $NAVISHAI_APP_HOST" http://127.0.0.1:3000/up >/dev/null; then ready=true; break; fi
    sleep 1
  done
  $ready || { vps_stop; vps_die 'Web readiness failed.'; return 1; }
  vps_policy_check || { vps_stop; return 1; }
  vps_compose up -d --pull never --no-build --no-deps proxy || { vps_stop; return 1; }
  vps_ingress_binding_check || { vps_stop; return 1; }
  ready=false
  for attempt in {1..60}; do
    if vps_https; then ready=true; break; fi
    sleep 2
  done
  $ready || { vps_stop; vps_die 'Verified local HTTPS failed. Check DNS/ACME/80/443; writers stopped.'; return 1; }
  vps_receipt "$(cat "$VPS_RELEASE/SOURCE_COMMIT")" ready
}
vps_services_check() {
  local service id
  for service in postgres app-net web jobs proxy; do
    id="$(vps_compose ps -q "$service")" || return 1
    [[ $id =~ ^[0-9a-f]{64}$ && $(vps_docker inspect --format '{{.State.Running}}' "$id") == true ]] || { vps_die "Service unavailable: $service"; return 1; }
  done
  curl --noproxy '*' --fail --silent --max-time 5 --header "Host: $NAVISHAI_APP_HOST" http://127.0.0.1:3000/up >/dev/null
}
vps_check() {
  vps_policy_check && vps_runtime_check && vps_services_check && vps_ingress_binding_check || { vps_stop; return 1; }
}
vps_units() (
  mkdir -p -- "$VPS_UNITS" "$(dirname -- "$VPS_CLI")" || return 1
  vps_directory "$VPS_UNITS" && vps_directory "$(dirname -- "$VPS_CLI")" || return 1
  local file temporary
  temporary="$(mktemp -d "$VPS_STATE/.units.XXXXXXXX")" || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  cat > "$temporary/navishai-reset.service" <<UNIT
[Unit]
Description=NavishAI reset gated startup
Requires=docker.service network-online.target
After=docker.service network-online.target
BindsTo=docker.service
PartOf=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$VPS_CLI --root $VPS_ROOT start
ExecStop=$VPS_CLI --root $VPS_ROOT stop
ExecStopPost=$VPS_CLI --root $VPS_ROOT stop
TimeoutStartSec=600
TimeoutStopSec=90
[Install]
WantedBy=multi-user.target docker.service
UNIT
  cat > "$temporary/navishai-reset-check.service" <<UNIT
[Unit]
Description=NavishAI reset fail-closed policy check
After=navishai-reset.service
ConditionPathExists=$VPS_STATE/install.json
[Service]
Type=oneshot
ExecStart=$VPS_CLI --root $VPS_ROOT check
UNIT
  cat > "$temporary/navishai-reset-check.timer" <<'UNIT'
[Unit]
Description=Check NavishAI reset namespace binding
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
Unit=navishai-reset-check.service
[Install]
WantedBy=timers.target
UNIT
  for file in navishai-reset.service navishai-reset-check.service navishai-reset-check.timer; do
    if [[ -e $VPS_UNITS/$file || -L $VPS_UNITS/$file ]]; then
      [[ -f $VPS_UNITS/$file && ! -L $VPS_UNITS/$file && $(stat -c '%u:%a:%h' -- "$VPS_UNITS/$file") == 0:644:1 ]] && cmp -s -- "$temporary/$file" "$VPS_UNITS/$file" || { vps_die "Existing unclaimed service/CLI: $file"; return 1; }
    fi
  done
  if [[ -e $VPS_CLI || -L $VPS_CLI ]]; then
    [[ -L $VPS_CLI && $(stat -c %u -- "$VPS_CLI") == 0 && $(readlink -- "$VPS_CLI") == "$VPS_PREFIX/current/bin/navishai-vps" ]] || { vps_die 'Existing unclaimed CLI.'; return 1; }
  else ln -s "$VPS_PREFIX/current/bin/navishai-vps" "$VPS_CLI" || return 1; fi
  for file in navishai-reset.service navishai-reset-check.service navishai-reset-check.timer; do
    [[ -e $VPS_UNITS/$file ]] || install -m 644 -- "$temporary/$file" "$VPS_UNITS/$file" || return 1
  done
  systemctl daemon-reload && systemctl enable navishai-reset.service navishai-reset-check.timer
)
vps_fresh_check() {
  local path existing
  for path in "$VPS_PREFIX" "$VPS_CONFIG" "$VPS_STATE" "$VPS_CLI" "$VPS_LEGACY_CLI"; do [[ ! -e $path && ! -L $path ]] || { vps_die "Fresh install path exists: $path"; return 1; }; done
  # No reuse of a manual/old project's state, even when the name happens to match.
  existing="$(vps_docker ps -aq --filter "label=com.docker.compose.project=$VPS_PROJECT")" || return 1
  [[ -z $existing ]] || { vps_die 'Project containers already exist; refuse adoption.'; return 1; }
  existing="$(vps_docker volume ls -q)" || return 1
  while IFS= read -r path; do
    case "$path" in navishai-reset_lab_postgres_data|navishai-reset_rails_storage|navishai-reset_caddy_data|navishai-reset_caddy_config) vps_die "Named volume already exists, even without labels: $path"; return 1 ;; esac
  done <<< "$existing"
  existing="$(vps_docker network ls --format '{{.Name}}')" || return 1
  while IFS= read -r path; do
    case "$path" in navishai-reset_control|navishai-reset_edge) vps_die "Named network already exists, even without labels: $path"; return 1 ;; esac
  done <<< "$existing"
}
vps_install() {
  [[ -n $source && -n $commit && -n $envfile ]] || { vps_die 'Install requires reviewed --source and --commit.'; return 1; }
  vps_fresh_check && vps_private "$envfile" || return 1
  mkdir -p -m 700 -- "$VPS_PREFIX" "$VPS_CONFIG" "$VPS_STATE"
  vps_directory "$VPS_PREFIX" && vps_directory "$VPS_CONFIG" && vps_directory "$VPS_STATE" || return 1
  vps_lock || return 1
  if ! { install -m 600 -- "$envfile" "$VPS_CONFIG/env" && vps_load_env && vps_ingress_check && vps_archive "$source" "$commit" >/dev/null && vps_switch "$commit" installing && vps_load; }; then
    # These roots did not exist before this invocation; no Docker work has run.
    rm -rf --one-file-system -- "$VPS_PREFIX" "$VPS_CONFIG" "$VPS_STATE" || return 1
    return 1
  fi
  vps_finish_install
}
vps_resume() {
  vps_load && vps_lock || return 1
  [[ $commit == "$(cat "$VPS_RELEASE/SOURCE_COMMIT")" ]] || { vps_die 'Resume requires the installed commit; use a backed-up upgrade to change releases.'; return 1; }
  vps_rename_cli && vps_cleanup_plan >/dev/null && vps_stop && vps_ingress_check || return 1
  vps_finish_install
}
vps_finish_install() {
  vps_compose build web jobs || return 1
  vps_pull_pins || return 1
  vps_compose up -d --pull never --no-build --no-deps --wait postgres app-net && vps_guard && vps_prepare && vps_validate || return 1
  vps_units || return 1
  # The systemd child must take the same lock, not collide with this installer.
  flock -u "$VPS_LOCK" || return 1
  systemctl restart navishai-reset.service navishai-reset-check.timer || return 1
  printf 'Installed reviewed reset. Open https://%s; bootstrap token stays in private env.\n' "$NAVISHAI_APP_HOST"
}
vps_candidate() {
  vps_switch "$commit" upgrading || return 1
  # Backup captured the old env first. Legacy configuration becomes portable auto.
  vps_write_ingress "${listen_address:-${NAVISHAI_PUBLIC_LISTEN_ADDRESS:-auto}}" || return 1
  vps_load && vps_ingress_check || return 1
  rm -f -- "$VPS_STATE/recovery-images.yaml"
  vps_compose build web jobs && vps_pull_pins || return 1
  vps_compose up -d --pull never --no-build --no-deps --wait postgres app-net && vps_guard && vps_prepare && vps_validate && vps_start
}
vps_git() { GIT_TERMINAL_PROMPT=0 git -c safe.directory="$source" -C "$source" "$@"; }
vps_latest_main() {
  if [[ ! -e $source && ! -L $source ]]; then
    printf 'Cloning %s into %s\n' "$VPS_REPOSITORY" "$source" >&2
    mkdir -p -m 700 -- "$(dirname -- "$source")" &&
      GIT_TERMINAL_PROMPT=0 git clone --quiet --no-checkout -- "$VPS_REPOSITORY" "$source" || { vps_die "Could not clone $VPS_REPOSITORY."; return 1; }
  fi
  vps_directory "$source" || return 1
  vps_git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' || { vps_die "Could not fetch main into $source."; return 1; }
  vps_git rev-parse --verify 'refs/remotes/origin/main^{commit}'
}
vps_upgrade_consent() {
  local installed="$1" answer
  printf 'Installed:   %s\nLatest main: %s\n' "$installed" "$commit"
  vps_git log --oneline --no-decorate -20 "$installed..$commit" 2>/dev/null || printf '(installed commit is not in this checkout'"'"'s history)\n'
  "$yes" && return 0
  [[ -t 0 ]] || { vps_die 'Confirm on a terminal, or add --yes.'; return 1; }
  read -r -p 'Back up, then upgrade to latest main? [y/N] ' answer || return 1
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || { printf 'Upgrade cancelled; nothing changed.\n'; return 1; }
}
vps_upgrade() {
  local installed latest=false
  installed="$(cat "$VPS_RELEASE/SOURCE_COMMIT")" || return 1
  source="${source:-$VPS_SOURCE}"
  # Without a pinned --commit, the target is whatever main is now.
  if [[ -z $commit ]]; then commit="$(vps_latest_main)" || return 1; latest=true; fi
  if [[ $commit == "$installed" ]]; then
    vps_rename_cli || return 1
    if "$latest"; then printf 'Already on latest main (%s); nothing to upgrade.\n' "$commit"
    else printf 'Already on %s; nothing to upgrade.\n' "$commit"; fi
    return 0
  fi
  if "$latest"; then vps_upgrade_consent "$installed" || return 1; fi
  if [[ -z $backup ]]; then
    backup="$VPS_BACKUPS/$(date -u +%Y%m%d-%H%M%S)-${installed:0:7}-to-${commit:0:7}"
    install -d -m 700 -- "$VPS_BACKUPS" || return 1
  fi
  local VPS_INGRESS_OVERRIDE="${listen_address:-}"
  vps_resolve_ingress "${listen_address:-${NAVISHAI_PUBLIC_LISTEN_ADDRESS:-auto}}" || return 1
  vps_archive "$source" "$commit" >/dev/null || return 1
  vps_backup "$backup" || return 1
  if vps_candidate; then printf 'Upgrade passed runtime/schema/policy gates. Recovery point: %s\n' "$backup";
  else
    vps_stop || return 1
    vps_restore "$backup" || { vps_die "Rollback failed; remain stopped. Recovery point: $backup"; return 1; }
    vps_load_env || return 1
    vps_die "Upgrade failed; old full recovery point restored, writers stopped. Inspect then run start. Backup: $backup"
    return 1
  fi
  vps_rename_cli || :
  vps_check && vps_status || { vps_die "Upgraded to $commit, but verification failed; writers stopped. Backup: $backup"; return 1; }
}
vps_status() {
  printf 'Release: %s\n' "$(cat "$VPS_RELEASE/SOURCE_COMMIT")"
  vps_compose ps
  vps_policy_check && vps_runtime_check && vps_services_check || return 1
  printf 'Verified local HTTPS: '
  vps_https && echo reachable
}
# One-time move from the old navishai-reset command. Units, paths and Compose
# resources keep their navishai-reset names; renaming volumes would move data.
vps_rename_cli() {
  [[ -e $VPS_LEGACY_CLI || -L $VPS_LEGACY_CLI ]] || return 0
  local target="$VPS_PREFIX/current/bin/navishai-vps" file content
  [[ -L $VPS_LEGACY_CLI && $(stat -c %u -- "$VPS_LEGACY_CLI") == 0 && $(readlink -- "$VPS_LEGACY_CLI") == "$target" ]] || { vps_die "Unclaimed legacy CLI: $VPS_LEGACY_CLI"; return 1; }
  for file in navishai-reset.service navishai-reset-check.service; do
    [[ ! -e $VPS_UNITS/$file && ! -L $VPS_UNITS/$file ]] && continue
    [[ -f $VPS_UNITS/$file && ! -L $VPS_UNITS/$file && $(stat -c '%u:%a:%h' -- "$VPS_UNITS/$file") == 0:644:1 ]] || { vps_die "Unclaimed unit: $file"; return 1; }
  done
  if [[ -e $VPS_CLI || -L $VPS_CLI ]]; then
    [[ -L $VPS_CLI && $(stat -c %u -- "$VPS_CLI") == 0 && $(readlink -- "$VPS_CLI") == "$target" ]] || { vps_die "Existing unclaimed CLI: $VPS_CLI"; return 1; }
  else ln -s "$target" "$VPS_CLI" || return 1; fi
  for file in navishai-reset.service navishai-reset-check.service; do
    [[ -f $VPS_UNITS/$file ]] || continue
    content="$(cat -- "$VPS_UNITS/$file")" || return 1
    printf '%s\n' "${content//"$VPS_LEGACY_CLI --root "/"$VPS_CLI --root "}" > "$VPS_UNITS/.$file.new" &&
      chmod 644 -- "$VPS_UNITS/.$file.new" && mv -f -- "$VPS_UNITS/.$file.new" "$VPS_UNITS/$file" || return 1
  done
  # Units must point at the new name before the old link disappears.
  systemctl daemon-reload && rm -f -- "$VPS_LEGACY_CLI" || return 1
  printf 'Renamed the command: use sudo navishai from now on.\n'
}
vps_cleanup_plan() {
  local inventory owned ids name metadata volumes='[]' networks='[]' paths mounts digest file
  inventory="$(vps_container_inventory)" && owned="$(vps_owned_containers "$inventory")" || return 1
  ids="$(jq -c '[.[].id]' <<< "$owned")" || return 1
  # Inspect every project volume/network, not just the currently attached ones.
  local names
  names="$(vps_docker volume ls -q --filter "label=com.docker.compose.project=$VPS_PROJECT")" || return 1
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    metadata="$(vps_docker volume inspect "$name" | jq -ec 'if length == 1 then .[0] else error("volume ambiguity") end')" || return 1
    jq -e --arg p "$VPS_PROJECT" '.Labels["com.navishai.owner"] == "navishai-reset" and .Labels["com.docker.compose.project"] == $p and (.Labels["com.docker.compose.volume"] as $v | ["lab_postgres_data","rails_storage","caddy_data","caddy_config"] | index($v) != null) and .Driver == "local" and ((.Options // {}) | length == 0) and .Name == ($p + "_" + .Labels["com.docker.compose.volume"])' <<< "$metadata" >/dev/null || { vps_die "Unowned/external/custom project volume: $name"; return 1; }
    jq -e --arg name "$name" --argjson ids "$ids" 'all(.[]; (.id as $id | $ids | index($id) != null) or all(.mounts[]; .Type != "volume" or .Name != $name))' <<< "$inventory" >/dev/null || { vps_die "Shared volume: $name"; return 1; }
    volumes="$(jq -c --argjson v "$metadata" '. + [$v]' <<< "$volumes")" || return 1
  done <<< "$names"
  names="$(vps_docker network ls -q --no-trunc --filter "label=com.docker.compose.project=$VPS_PROJECT")" || return 1
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    metadata="$(vps_docker network inspect "$name" | jq -ec 'if length == 1 then .[0] else error("network ambiguity") end')" || return 1
    jq -e --arg p "$VPS_PROJECT" --argjson ids "$ids" '.Labels["com.navishai.owner"] == "navishai-reset" and .Labels["com.docker.compose.project"] == $p and (.Labels["com.docker.compose.network"] as $n | ["control","edge"] | index($n) != null) and .Name == ($p + "_" + .Labels["com.docker.compose.network"]) and all((.Containers // {} | keys)[]; . as $id | $ids | index($id) != null)' <<< "$metadata" >/dev/null || { vps_die "Unowned/shared project network: $name"; return 1; }
    networks="$(jq -c --argjson n "$metadata" '. + [$n]' <<< "$networks")" || return 1
  done <<< "$names"
  paths="$(jq -nc --arg p "$VPS_PREFIX" --arg c "$VPS_CONFIG" --arg s "$VPS_STATE" --arg cli "$VPS_CLI" --arg u "$VPS_UNITS" '[$p,$c,$s,$cli,($u+"/navishai-reset.service"),($u+"/navishai-reset-check.service"),($u+"/navishai-reset-check.timer")]')"
  mounts="$(findmnt --json -o TARGET | jq -ec '[.. | objects | .target? // empty]')" || return 1
  jq -e --argjson paths "$paths" 'all(.[]; . as $m | all($paths[]; . as $p | $m != $p and ($m | startswith($p + "/") | not)))' <<< "$mounts" >/dev/null || { vps_die 'Mounted filesystem under managed paths.'; return 1; }
  jq -e --argjson ids "$ids" --argjson paths "$paths" 'all(.[]; (.id as $id | $ids | index($id) != null) or all(.mounts[]; .Type != "bind" or (.Source as $b | all($paths[]; . as $p | $b != $p and ($b | startswith($p + "/") | not) and ($p | startswith($b + "/") | not)))))' <<< "$inventory" >/dev/null || { vps_die 'Foreign container shares a managed bind path.'; return 1; }
  jq -e --argjson volumes "$volumes" --arg p "$VPS_PREFIX" 'all(.[].mounts[]; (.Type == "volume" and (.Name as $name | $volumes | any(.Name == $name))) or (.Type == "bind" and (.Source | startswith($p + "/releases/"))))' <<< "$owned" >/dev/null || { vps_die 'Unexpected external/bind mount on a managed container.'; return 1; }
  if [[ -e $VPS_CLI || -L $VPS_CLI ]]; then
    [[ -L $VPS_CLI && $(realpath -e -- "$VPS_CLI") == "$VPS_RELEASE/bin/navishai-vps" ]] || { vps_die 'Unclaimed reset CLI.'; return 1; }
  else
    [[ $(jq -r .phase "$VPS_STATE/install.json") =~ ^(installing|recovering)$ ]] || return 1
  fi
  local -a units=()
  for file in navishai-reset.service navishai-reset-check.service navishai-reset-check.timer; do
    if [[ ! -e $VPS_UNITS/$file && ! -L $VPS_UNITS/$file ]]; then
      [[ $(jq -r .phase "$VPS_STATE/install.json") =~ ^(installing|recovering)$ ]] || return 1
      continue
    fi
    [[ -f $VPS_UNITS/$file && ! -L $VPS_UNITS/$file && $(stat -c %u "$VPS_UNITS/$file") == 0 ]] || { vps_die "Unclaimed unit: $file"; return 1; }
    [[ $file == *.timer ]] || grep -Fq "ExecStart=$VPS_CLI --root $VPS_ROOT " "$VPS_UNITS/$file" || return 1
    units+=("$VPS_UNITS/$file")
  done
  # One digest binds code/config/state without printing secrets or their own hashes.
  digest="$( { find "$VPS_PREFIX" "$VPS_CONFIG" "$VPS_STATE" -type f ! -name install.lock -print0 | sort -z | xargs -0 sha256sum; if ((${#units[@]})); then sha256sum "${units[@]}"; fi; } | sha256sum | cut -d' ' -f1)" || return 1
  jq -nS --argjson containers "$owned" --argjson volumes "$volumes" --argjson networks "$networks" --argjson paths "$paths" --arg digest "$digest" '{project:"navishai-reset",containers:($containers|sort_by(.id)|map(.id)),volumes:($volumes|sort_by(.Name)),networks:($networks|sort_by(.Id)),paths:$paths,files_digest:$digest}'
}
vps_cleanup() {
  local apply="$1" confirmation="$2" plan digest fresh name
  plan="$(vps_cleanup_plan)" || return 1
  digest="$(sha256sum <<< "$plan" | cut -d' ' -f1)"
  printf '%s\nPlan SHA256: %s\n' "$plan" "$digest"
  if ! "$apply"; then printf 'PREVIEW ONLY. Apply with --apply --confirm-destroy %s\n' "$digest"; return; fi
  [[ $confirmation == "$digest" ]] || { vps_die 'Plan changed or destruction consent missing.'; return 1; }
  fresh="$(vps_cleanup_plan)" || return 1
  [[ $fresh == "$plan" ]] || { vps_die 'Resources changed; preview again.'; return 1; }
  local -a array
  array=()
  for name in navishai-reset-check.timer navishai-reset.service; do [[ ! -f $VPS_UNITS/$name ]] || array+=("$name"); done
  if ((${#array[@]})); then systemctl disable --now "${array[@]}" || return 1; fi
  mapfile -t array < <(jq -r '.containers[]' <<< "$plan")
  if ((${#array[@]})); then vps_docker stop --time 60 "${array[@]}" && vps_docker rm "${array[@]}" || return 1; fi
  while IFS= read -r name; do vps_docker network rm "$name" || return 1; done < <(jq -r '.networks[].Id' <<< "$plan")
  while IFS= read -r name; do vps_docker volume rm "$name" || return 1; done < <(jq -r '.volumes[].Name' <<< "$plan")
  rm -f -- "$VPS_CLI" "$VPS_UNITS/navishai-reset.service" "$VPS_UNITS/navishai-reset-check.service" "$VPS_UNITS/navishai-reset-check.timer" || return 1
  systemctl daemon-reload || return 1
  rm -rf --one-file-system -- "$VPS_PREFIX" "$VPS_CONFIG" "$VPS_STATE" || return 1
  printf 'Removed only verified reset resources. Images/packages/external backups remain.\n'
}
vps_main() {
  local root=/ command= source= commit= envfile= backup= output= host= email= listen_address= from= confirmation= answers= apply=false non_interactive=false resume=false yes=false
  if [[ ${1:-} == --root ]]; then [[ $# -ge 3 ]] || return 1; root="$2"; shift 2; fi
  command="${1:-help}"; (($# == 0)) || shift
  case "$command" in help|--help|-h) vps_help; return ;; esac
  [[ $EUID == 0 ]] || { vps_die 'Run with sudo.'; return 1; }
  vps_paths "$root" || return 1
  while (($#)); do
    case "$1" in
      --source|--commit|--env|--backup|--output|--host|--acme-email|--public-listen-address|--from|--confirm-restore|--confirm-destroy|--answers)
        [[ $# -ge 2 ]] || { vps_die "Missing value: $1"; return 1; }
        case "$1" in
          --source) source="$(realpath -e -- "$2")" ;; --commit) commit="$2" ;; --env) envfile="$2" ;;
          --backup) backup="$2" ;; --output) output="$2" ;; --host) host="$2" ;; --acme-email) email="$2" ;;
          --public-listen-address) listen_address="$2" ;;
          --answers) answers="$2" ;;
          --from) from="$2" ;; --confirm-restore|--confirm-destroy) confirmation="$2" ;;
        esac
        shift 2 ;;
      --apply) apply=true; shift ;;
      --non-interactive) non_interactive=true; shift ;;
      --resume) resume=true; shift ;;
      --yes) yes=true; shift ;;
      *) vps_die "Unknown option: $1"; return 1 ;;
    esac
  done
  [[ -z $listen_address || $command == init-env || $command == install || $command == upgrade || $command == recover ]] || { vps_die '--public-listen-address is only for setup, backed-up upgrade or destination recovery.'; return 1; }
  [[ $command == install || ( -z $answers && $non_interactive == false ) ]] || return 1
  [[ $resume == false || $command == install || $command == recover ]] || return 1
  [[ $yes == false || $command == upgrade ]] || { vps_die '--yes is only for upgrade.'; return 1; }
  [[ $command != init-env ]] || { vps_init_env; return; }
  # Emergency stop does not need healthy config, Compose, Git or firewall tools.
  [[ $command != stop ]] || {
    command -v docker >/dev/null && command -v jq >/dev/null &&
      [[ $(vps_docker context inspect --format '{{.Endpoints.docker.Host}}') == unix:///* ]] && vps_stop
    return
  }
  vps_doctor || return 1
  [[ $command != doctor ]] || { printf 'Local tool/Docker prerequisites pass; DNS/ports/SMTP are not certified.\n'; return; }
  [[ $command != install ]] || { if [[ -n $envfile ]]; then [[ $resume == false && -z $answers ]] && vps_install; else vps_setup; fi; return; }
  [[ $command != recover ]] || { vps_recover; return; }
  case "$command" in cleanup) vps_load cleanup ;; restore) vps_load no-env ;; *) vps_load ;; esac || {
    case "$command" in check|start) vps_stop ;; esac
    return 1
  }
  vps_lock || return 1
  # Upgrade renames after switching releases; systemd's start/check never rewrite units.
  case "$command" in upgrade|start|check) ;; *) vps_rename_cli || return 1 ;; esac
  case "$command" in
    start) vps_start ;; stop) vps_stop ;; check) vps_check ;;
    status) vps_status ;;
    backup) [[ -n $output ]] || { vps_die 'backup needs --output.'; return 1; }; vps_backup "$output" && vps_start ;;
    upgrade) vps_upgrade ;;
    renew-bootstrap) vps_renew_bootstrap ;;
    restore) [[ -n $from && $confirmation =~ ^[0-9a-f]{64}$ && $(sha256sum "$from/CHECKSUMS" | cut -d' ' -f1) == "$confirmation" ]] || { vps_die 'Inspect backup; --confirm-restore needs CHECKSUMS SHA256 (all payloads).' ; return 1; }; vps_restore "$from" && vps_load_env ;;
    cleanup) vps_cleanup "$apply" "$confirmation" ;;
    *) vps_die "Unknown command: $command"; return 1 ;;
  esac
}
