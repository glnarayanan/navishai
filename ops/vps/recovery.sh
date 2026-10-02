#!/usr/bin/env bash
# Sourced by the locked, root-only VPS CLI. Never source a backup or its env file.

vps_recovery_error() {
  printf 'Recovery refused or failed (%s); workloads must remain stopped.\n' "${1:-validation}" >&2
  return 1
}

# A canonical, root-owned path, with no links or writable non-sticky ancestors.
vps_recovery_path() {
  local path="$1" resolved mode
  [[ "$path" == /* && "$path" != / ]] || return 1
  resolved="$(realpath -e -- "$path")" || return 1
  [[ "$resolved" == "$path" && ! -L "$path" ]] || return 1
  while [[ "$path" != / ]]; do
    [[ "$(stat -c %u -- "$path")" == 0 ]] || return 1
    mode="$(stat -c %a -- "$path")" || return 1
    (( (8#$mode & 0022) == 0 || (8#$mode & 01000) != 0 )) || return 1
    path="$(dirname -- "$path")"
  done
}

vps_recovery_roots() {
  [[ "$EUID" == 0 && "$VPS_PROJECT" == navishai-reset ]] || return 1
  local path
  for path in "$VPS_PREFIX" "$VPS_PREFIX/releases" "$VPS_CONFIG" "$VPS_STATE"; do
    vps_recovery_path "$path" || return 1
    [[ -d "$path" ]] || return 1
  done
  [[ "$VPS_PREFIX" != "$VPS_CONFIG" && "$VPS_PREFIX" != "$VPS_STATE" && "$VPS_CONFIG" != "$VPS_STATE" ]] || return 1
  [[ "$(stat -c %a "$VPS_CONFIG")" == 700 && "$(stat -c %a "$VPS_STATE")" == 700 ]] || return 1
  [[ -f "$VPS_CONFIG/env" && ! -L "$VPS_CONFIG/env" && "$(stat -c '%u:%a:%h' "$VPS_CONFIG/env")" == 0:600:1 ]] || return 1
}

vps_recovery_stopped() {
  local running
  running="$(vps_compose ps --status running --services)" || return 1
  ! grep -Eq '^(web|jobs|proxy)$' <<< "$running"
}

vps_recovery_clients_stopped() {
  local answer
  answer="$(vps_recovery_sql postgres <<'SQL'
SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE backend_type='client backend'
AND datname IN ('navishai_lab_production','navishai_lab_production_cache','navishai_lab_production_queue','navishai_lab_production_cable'));
SQL
  )" || return 1
  [[ "$answer" == t ]]
}

vps_recovery_pg() {
  vps_compose exec -T postgres "$@"
}

vps_recovery_sql() {
  vps_recovery_pg psql -X -q -A -t -v ON_ERROR_STOP=1 -U navishai_admin -d "$1"
}

vps_recovery_pg_ready() {
  local i
  for ((i=0; i<60; i++)); do
    vps_recovery_pg pg_isready -U navishai_admin -d postgres >/dev/null 2>&1 && break
    sleep 1
  done
  [[ "$i" -lt 60 && "$(vps_recovery_sql postgres <<<'SHOW server_version_num;')" =~ ^16[0-9]{4}$ ]]
}

vps_recovery_image_ref() {
  vps_compose config --format json | jq -er --arg service "$1" '.services[$service].image'
}

# GNU tar lists every member without extraction. Links, special nodes, duplicate
# paths, control characters, set-id bits and foreign ownership fail closed.
vps_recovery_tar_check() {
  local archive="$1" kind="$2" listing mode owner size day time name normalized
  local -A seen=()
  listing="$(tar --list --verbose --numeric-owner --quoting-style=escape --quote-chars=' ' --file "$archive")" || return 1
  [[ -n "$listing" ]] || return 1
  while read -r mode owner size day time name; do
    [[ "$mode" =~ ^[-d][rwx-]{9}$ && "$size" =~ ^[0-9]+$ ]] || return 1
    [[ "$name" =~ ^[a-zA-Z0-9_./@+:=-]+$ && "$name" != /* ]] || return 1
    normalized="${name#./}"; normalized="${normalized%/}"
    [[ "$name" != ./ ]] || normalized=.
    [[ "$normalized" == . || ( -n "$normalized" && "/$normalized/" != *'/../'* && "/$normalized/" != *'/./'* && "$normalized" != *'//'* ) ]] || return 1
    [[ ! -v 'seen[$normalized]' ]] || return 1
    seen["$normalized"]=1
    case "$kind:$owner" in
      storage:0/0|storage:1000/1000|root:0/0|private:0/0|postgres:999/999|image:0/0) ;;
      *) return 1 ;;
    esac
    if [[ "$kind" == private ]]; then
      [[ "$mode" == -rw------- || "$mode" == drwx------ ]] || return 1
    elif [[ "$kind" == root ]]; then
      [[ "${mode:5:1}${mode:8:1}" == -- ]] || return 1
    elif [[ "$kind" == postgres ]]; then
      [[ "$mode" == -rw------- && "$normalized" =~ ^(postgresql\.conf|postgresql\.auto\.conf|pg_hba\.conf|pg_ident\.conf)$ ]] || return 1
    fi
  done <<< "$listing"
  [[ "$kind" != postgres || "${#seen[@]}" == 4 ]]
}

vps_recovery_volume() {
  local key="$1" name="${VPS_PROJECT}_$1" labels users user service
  labels="$(vps_docker volume inspect --format '{{.Driver}}/{{json .Options}}/{{index .Labels "com.docker.compose.project"}}/{{index .Labels "com.docker.compose.volume"}}/{{index .Labels "com.navishai.owner"}}' "$name")" || return 1
  [[ "$labels" == "local/null/$VPS_PROJECT/$key/$VPS_PROJECT" || "$labels" == "local/{}/$VPS_PROJECT/$key/$VPS_PROJECT" ]] || return 1
  users="$(vps_docker ps --all --quiet --no-trunc --filter "volume=$name")" || return 1
  while read -r user; do
    [[ -n "$user" ]] || continue
    labels="$(vps_docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.navishai.owner"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$user")" || return 1
    service="${labels##*/}"
    [[ "$labels" == "$VPS_PROJECT/$VPS_PROJECT/$service" ]] || return 1
    case "$key:$service" in
      lab_postgres_data:postgres|rails_storage:web|rails_storage:jobs|caddy_data:proxy|caddy_config:proxy) ;;
      *) return 1 ;;
    esac
    [[ "$user" == "$(vps_compose ps --all -q "$service")" ]] || return 1
  done <<< "$users"
  printf '%s\n' "$name"
}

vps_recovery_volume_dump() {
  local name
  name="$(vps_recovery_volume "$1")" || return 1
  vps_docker run --rm --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges --user 0:0 --mount "type=volume,src=$name,dst=/data,readonly" \
    --entrypoint tar "$2" --format=ustar --hard-dereference -cf - -C /data .
}

vps_recovery_volume_restore() {
  local key="$1" image="$2" archive="$3" name="${VPS_PROJECT}_$1"
  if ! vps_docker volume inspect "$name" >/dev/null 2>&1; then
    vps_docker volume create --label "com.docker.compose.project=$VPS_PROJECT" \
      --label "com.docker.compose.volume=$key" --label "com.navishai.owner=$VPS_PROJECT" "$name" >/dev/null || return 1
  fi
  vps_recovery_volume "$key" >/dev/null || return 1
  # No symlink traversal: GNU find removes entries, not targets outside /data.
  vps_docker run --rm -i --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE \
    --cap-add CHOWN --cap-add FOWNER --security-opt no-new-privileges --user 0:0 \
    --mount "type=volume,src=$name,dst=/data" --entrypoint sh "$image" \
    -ec 'find /data -mindepth 1 -delete; exec tar --numeric-owner --same-owner --same-permissions -xf - -C /data' < "$archive"
}

vps_recovery_pg_config_dump() {
  local image="$1" name answer
  answer="$(vps_recovery_sql postgres <<'SQL'
SELECT current_setting('config_file')='/var/lib/postgresql/data/postgresql.conf'
AND current_setting('hba_file')='/var/lib/postgresql/data/pg_hba.conf'
AND current_setting('ident_file')='/var/lib/postgresql/data/pg_ident.conf'
AND NOT EXISTS (SELECT 1 FROM pg_file_settings WHERE error IS NOT NULL OR sourcefile NOT IN ('/var/lib/postgresql/data/postgresql.conf','/var/lib/postgresql/data/postgresql.auto.conf'))
AND NOT EXISTS (SELECT 1 FROM pg_hba_file_rules WHERE error IS NOT NULL OR file_name <> '/var/lib/postgresql/data/pg_hba.conf')
AND NOT EXISTS (SELECT 1 FROM pg_ident_file_mappings WHERE error IS NOT NULL OR file_name <> '/var/lib/postgresql/data/pg_ident.conf');
SQL
  )" || return 1
  [[ "$answer" == t ]] || return 1
  name="$(vps_recovery_volume lab_postgres_data)" || return 1
  vps_docker run --rm --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges --user 0:0 --mount "type=volume,src=$name,dst=/data,readonly" \
    --entrypoint tar "$image" --format=ustar -cf - -C /data postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf
}

vps_recovery_pg_config_restore() {
  local name
  name="$(vps_recovery_volume lab_postgres_data)" || return 1
  vps_compose stop postgres >/dev/null || return 1
  vps_docker run --rm -i --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE \
    --cap-add CHOWN --cap-add FOWNER --security-opt no-new-privileges --user 0:0 \
    --mount "type=volume,src=$name,dst=/data" --entrypoint sh "$1" \
    -ec 'rm -f /data/postgresql.conf /data/postgresql.auto.conf /data/pg_hba.conf /data/pg_ident.conf; exec tar --numeric-owner --same-owner --same-permissions -xf - -C /data' < "$2" || return 1
  vps_compose up -d --no-deps --pull never postgres >/dev/null
}

# Deliberately scoped, not pg_dumpall: no other role, membership or global is saved.
# Only restricted app roles enter this file; navishai_admin remains local.
vps_recovery_roles_dump() {
  vps_recovery_sql postgres <<'SQL'
SELECT rolname || E'\t' || rolpassword || E'\t' || rolsuper || E'\t' || rolcreatedb || E'\t' || rolcreaterole || E'\t' || rolreplication || E'\t' || rolbypassrls || E'\t' || rolinherit || E'\t' || rolconnlimit
FROM pg_authid WHERE rolname IN ('navishai_setup','navishai') AND rolcanlogin AND rolvaliduntil IS NULL
AND NOT EXISTS (SELECT 1 FROM pg_db_role_setting WHERE setrole = pg_authid.oid)
AND NOT EXISTS (SELECT 1 FROM pg_auth_members WHERE roleid = pg_authid.oid OR member = pg_authid.oid)
ORDER BY rolname;
SQL
}

vps_recovery_roles_check() {
  local path="$1" role hash super db create replication bypass inherit limit extra count=0
  while IFS=$'\t' read -r role hash super db create replication bypass inherit limit extra; do
    ((count+=1))
    [[ -z "$extra" && "$hash" =~ ^SCRAM-SHA-256\$[0-9]+:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$ ]] || return 1
    [[ "$inherit" =~ ^(true|false)$ && "$limit" =~ ^(-1|[0-9]+)$ ]] || return 1
    if [[ "$count" == 1 ]]; then
      [[ "$role:$super:$db:$create:$replication:$bypass" == navishai:false:false:false:false:false ]] || return 1
    elif [[ "$count" == 2 ]]; then
      [[ "$role:$super:$db:$create:$replication:$bypass" == navishai_setup:false:false:false:false:false ]] || return 1
    else
      return 1
    fi
  done < "$path"
  [[ "$count" == 2 ]]
}

vps_recovery_roles_restore() {
  local role hash super db create replication bypass inherit limit
  while IFS=$'\t' read -r role hash super db create replication bypass inherit limit; do
    # All values have passed the fixed grammar above; no backup SQL is executed.
    printf 'ALTER ROLE %s WITH %s %s %s %s %s %s LOGIN CONNECTION LIMIT %s PASSWORD '\''%s'\'';\n' \
      "$role" "$([[ "$super" == true ]] && echo SUPERUSER || echo NOSUPERUSER)" \
      "$([[ "$db" == true ]] && echo CREATEDB || echo NOCREATEDB)" \
      "$([[ "$create" == true ]] && echo CREATEROLE || echo NOCREATEROLE)" \
      "$([[ "$replication" == true ]] && echo REPLICATION || echo NOREPLICATION)" \
      "$([[ "$bypass" == true ]] && echo BYPASSRLS || echo NOBYPASSRLS)" \
      "$([[ "$inherit" == true ]] && echo INHERIT || echo NOINHERIT)" "$limit" "$hash"
  done < "$1" | vps_recovery_sql postgres
}

vps_recovery_database_check() {
  local answer
  answer="$(vps_recovery_sql "$1" <<'SQL'
SELECT (SELECT datdba = 'navishai_setup'::regrole FROM pg_database WHERE datname=current_database())
AND NOT EXISTS (SELECT 1 FROM pg_shdepend WHERE
(dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) OR
(dbid=0 AND classid='pg_database'::regclass AND objid=(SELECT oid FROM pg_database WHERE datname=current_database())))
AND refclassid='pg_authid'::regclass AND refobjid NOT IN ('navishai_setup'::regrole,'navishai'::regrole,'pg_database_owner'::regrole));
SQL
  )" || return 1
  [[ "$answer" == t ]]
}

# Fixed artifact set. The checksum file itself contains no caller-chosen paths.
vps_recovery_files() {
  printf '%s\n' manifest roles.tsv release.tar config.tar state.tar images.tar \
    primary.dump cache.dump queue.dump cable.dump rails_storage.tar caddy_data.tar caddy_config.tar postgres-config.tar
}

vps_recovery_checksums() {
  local file
  while read -r file; do
    sha256sum -- "$file" || return 1
  done < <(vps_recovery_files)
}

vps_recovery_dump_check() {
  local dump="$1" database="$2" image="$3" listing
  listing="$(vps_docker run --rm -i --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --entrypoint pg_restore "$image" --create --list < "$dump")" || return 1
  [[ "$(grep -cE '^[0-9]+; [0-9]+ [0-9]+ DATABASE - ' <<< "$listing")" == 1 ]] || return 1
  grep -Eq "^[0-9]+; [0-9]+ [0-9]+ DATABASE - $database navishai_setup$" <<< "$listing"
}

vps_recovery_manifest_check() {
  local directory="$1" key service value id extra first=1
  local -A images=()
  VPS_RECOVERY_SERVICES=(); VPS_RECOVERY_IMAGES=(); VPS_RECOVERY_IDS=(); VPS_RECOVERY_SHA=; VPS_RECOVERY_PG_IMAGE=
  while IFS=$'\t' read -r key service value id extra; do
    [[ -z "$extra" ]] || return 1
    if ((first)); then
      [[ "$key" == navishai-reset-backup-v1 && -z "$service$value$id" ]] || return 1
      first=0
    elif [[ -z "$VPS_RECOVERY_SHA" ]]; then
      [[ "$key" == release && "$service" =~ ^[a-f0-9]{40}$ && -z "$value$id" ]] || return 1
      VPS_RECOVERY_SHA="$service"
    elif [[ -z "$VPS_RECOVERY_PG_IMAGE" ]]; then
      [[ "$key" == postgres && "$service" =~ ^sha256:[a-f0-9]{64}$ && -z "$value$id" ]] || return 1
      VPS_RECOVERY_PG_IMAGE="$service"
    else
      [[ "$key" == image && "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./:@-]*$ && "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
      [[ "$service" =~ ^(postgres|web|jobs|proxy|app-net)$ && ! -v 'images[$service]' ]] || return 1
      [[ "$service" != postgres || "$id" == "$VPS_RECOVERY_PG_IMAGE" ]] || return 1
      images["$service"]=1; VPS_RECOVERY_SERVICES+=("$service"); VPS_RECOVERY_IMAGES+=("$value"); VPS_RECOVERY_IDS+=("$id")
    fi
  done < "$directory/manifest"
  [[ "${#VPS_RECOVERY_IMAGES[@]}" == 5 && -n "$VPS_RECOVERY_PG_IMAGE" ]] || return 1
}

vps_recovery_backup_check() {
  local directory="$1" file count=0
  vps_recovery_path "$directory" || return 1
  [[ -d "$directory" && "$(stat -c %a "$directory")" == 700 ]] || return 1
  while IFS= read -r -d '' file; do
    [[ -f "$file" && ! -L "$file" && "$(stat -c '%u:%a:%h' "$file")" == 0:600:1 ]] || return 1
    ((count+=1))
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
  [[ "$count" == 15 ]] || return 1
  while read -r file; do [[ -f "$directory/$file" ]] || return 1; done < <(vps_recovery_files)
  [[ -f "$directory/CHECKSUMS" ]] || return 1
  (cd "$directory" && vps_recovery_checksums) > "$VPS_RECOVERY_WORK/checksums" || return 1
  cmp -s "$VPS_RECOVERY_WORK/checksums" "$directory/CHECKSUMS" || return 1
  vps_recovery_manifest_check "$directory" || return 1
  vps_recovery_roles_check "$directory/roles.tsv" || return 1
  vps_recovery_tar_check "$directory/release.tar" root || return 1
  vps_recovery_tar_check "$directory/config.tar" private || return 1
  vps_recovery_tar_check "$directory/state.tar" private || return 1
  vps_recovery_tar_check "$directory/rails_storage.tar" storage || return 1
  vps_recovery_tar_check "$directory/caddy_data.tar" root || return 1
  vps_recovery_tar_check "$directory/caddy_config.tar" root || return 1
  # Docker's OCI layer blobs use 0666 headers. They remain opaque to Docker load,
  # never filesystem extraction; the enclosing image archive is still root 0600.
  vps_recovery_tar_check "$directory/images.tar" image || return 1
  vps_recovery_tar_check "$directory/postgres-config.tar" postgres || return 1
}

vps_backup() (
  # Explicit failure checks also work when a caller invokes this function in `if`.
  set +x
  set +e
  trap - ERR DEBUG RETURN
  set -uo pipefail
  umask 077
  export LC_ALL=C TZ=UTC
  local destination="${1:-}" parent release sha pgid reference id key database success=0 phase=preflight
  local VPS_RECOVERY_WORK= stage=
  exec 3>&2
  trap 'status=$?; if (( ! success )); then vps_stop >/dev/null 2>&1 || :; vps_recovery_error "$phase" >&3 || :; fi; [[ -z "$stage" ]] || rm -rf -- "$stage"; [[ -z "$VPS_RECOVERY_WORK" ]] || rm -rf -- "$VPS_RECOVERY_WORK"; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  [[ $# == 1 ]] || exit 1
  vps_stop >/dev/null 2>&1 || exit 1
  vps_recovery_roots >/dev/null 2>&1 || exit 1
  [[ "$destination" == /* && "$destination" != */ && ! -e "$destination" && ! -L "$destination" ]] || exit 1
  parent="$(dirname -- "$destination")"
  vps_recovery_path "$parent" >/dev/null 2>&1 || exit 1
  # Never put a backup or scratch tree inside the data it captures.
  for key in "$VPS_PREFIX" "$VPS_CONFIG" "$VPS_STATE"; do
    [[ "$parent/" != "$key/"* ]] || exit 1
  done
  VPS_RECOVERY_WORK="$(mktemp -d "$parent/.recovery-check.XXXXXXXX")" || exit 1
  stage="$(mktemp -d "$parent/.recovery-backup.XXXXXXXX")" || exit 1
  # All tool output, including SQL and Docker errors, stays private and is removed.
  exec 2>"$VPS_RECOVERY_WORK/errors"
  vps_recovery_stopped || exit 1
  release="$(realpath -e -- "$VPS_RELEASE")" || exit 1
  sha="${release##*/}"
  [[ "$sha" =~ ^[a-f0-9]{40}$ && "$release" == "$VPS_PREFIX/releases/$sha" ]] || exit 1
  vps_recovery_path "$release" || exit 1
  [[ "$(cat "$release/SOURCE_COMMIT")" == "$sha" && "$(realpath -e "$VPS_PREFIX/current")" == "$release" ]] || exit 1
  phase=images
  [[ "$(vps_recovery_sql postgres <<<'SHOW server_version_num;')" =~ ^16[0-9]{4}$ ]] || exit 1
  pgid="$(vps_docker inspect --format '{{.Image}}' "$(vps_compose ps -q postgres)")" || exit 1
  [[ "$pgid" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
  printf 'navishai-reset-backup-v1\nrelease\t%s\npostgres\t%s\n' "$sha" "$pgid" > "$stage/manifest"
  for key in postgres web jobs proxy app-net; do
    reference="$(vps_recovery_image_ref "$key")" || exit 1
    [[ "$reference" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./:@-]*$ ]] || exit 1
    id="$(vps_docker image inspect --format '{{.Id}}' "$reference")" || exit 1
    [[ "$id" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
    [[ "$(vps_docker inspect --format '{{.Image}}' "$(vps_compose ps --all -q "$key")")" == "$id" ]] || exit 1
    printf 'image\t%s\t%s\t%s\n' "$key" "$reference" "$id" >> "$stage/manifest"
  done
  vps_recovery_manifest_check "$stage" || exit 1
  # Save IDs (including digest-only images); Docker save cannot take RepoDigests.
  vps_docker image save "${VPS_RECOVERY_IDS[@]}" > "$stage/images.tar" || exit 1
  phase=roles
  vps_recovery_roles_dump > "$stage/roles.tsv" || exit 1
  vps_recovery_roles_check "$stage/roles.tsv" || exit 1
  phase=databases
  vps_recovery_clients_stopped || exit 1
  for key in primary cache queue cable; do
    database=navishai_lab_production
    [[ "$key" == primary ]] || database+="_$key"
    vps_recovery_database_check "$database" || exit 1
    vps_recovery_pg pg_dump -U navishai_admin -d "$database" --format=custom --create > "$stage/$key.dump" || exit 1
  done
  phase=files
  vps_recovery_pg_config_dump "$pgid" > "$stage/postgres-config.tar" || exit 1
  tar --format=ustar --hard-dereference -cf "$stage/release.tar" -C "$release" . || exit 1
  tar --format=ustar --hard-dereference -cf "$stage/config.tar" -C "$VPS_CONFIG" . || exit 1
  # The held lock's inode must survive restore. It is not bootstrap state.
  tar --format=ustar --hard-dereference --exclude=./install.lock -cf "$stage/state.tar" -C "$VPS_STATE" . || exit 1
  phase=volumes
  for key in rails_storage caddy_data caddy_config; do
    vps_recovery_volume_dump "$key" "$pgid" > "$stage/$key.tar" || exit 1
  done
  phase=validation
  chmod 600 "$stage/"* || exit 1
  (cd "$stage" && vps_recovery_checksums > CHECKSUMS) || exit 1
  vps_recovery_backup_check "$stage" || exit 1
  phase=publication
  # Flush before the same-filesystem, no-replace publication. An old backup is
  # never overwritten, including a destination created while the copy runs.
  sync -f "$stage" || exit 1
  mv -T -n -- "$stage" "$destination" || exit 1
  [[ ! -e "$stage" ]] || exit 1
  stage=
  sync -f "$parent" || exit 1
  success=1
  # Caller may run vps_start after a normal backup; upgrade keeps writers stopped.
)

vps_recovery_restore() (
  set +x
  set +e
  trap - ERR DEBUG RETURN
  set -uo pipefail
  umask 077
  export LC_ALL=C TZ=UTC
  local source="${1:-}" key database release running i success=0 phase=validation
  local VPS_RECOVERY_WORK= VPS_RECOVERY_SHA VPS_RECOVERY_PG_IMAGE
  local -a VPS_RECOVERY_SERVICES=() VPS_RECOVERY_IMAGES=() VPS_RECOVERY_IDS=()
  exec 3>&2
  trap 'status=$?; vps_stop >/dev/null 2>&1 || :; if (( ! success )); then vps_recovery_error "$phase" >&3 || :; fi; [[ -z "$VPS_RECOVERY_WORK" ]] || rm -rf -- "$VPS_RECOVERY_WORK"; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  [[ $# == 1 ]] || exit 1
  vps_stop >/dev/null 2>&1 || exit 1
  vps_recovery_roots >/dev/null 2>&1 || exit 1
  VPS_RECOVERY_WORK="$(mktemp -d "$VPS_PREFIX/.recovery-restore.XXXXXXXX")" || exit 1
  exec 2>"$VPS_RECOVERY_WORK/errors"
  vps_recovery_stopped || exit 1
  vps_recovery_backup_check "$source" || exit 1
  # Copy trusted, private fixed files before using them, then check the copy.
  mkdir -m 700 "$VPS_RECOVERY_WORK/backup" || exit 1
  while read -r key; do cp -- "$source/$key" "$VPS_RECOVERY_WORK/backup/$key" || exit 1; done < <(vps_recovery_files)
  cp -- "$source/CHECKSUMS" "$VPS_RECOVERY_WORK/backup/CHECKSUMS" || exit 1
  source="$VPS_RECOVERY_WORK/backup"
  vps_recovery_backup_check "$source" || exit 1
  mkdir -m 700 "$VPS_RECOVERY_WORK/release" "$VPS_RECOVERY_WORK/config" "$VPS_RECOVERY_WORK/state" || exit 1
  for key in release config state; do
    tar --numeric-owner --same-owner --same-permissions -xf "$source/$key.tar" -C "$VPS_RECOVERY_WORK/$key" || exit 1
  done
  [[ "$(cat "$VPS_RECOVERY_WORK/release/SOURCE_COMMIT")" == "$VPS_RECOVERY_SHA" ]] || exit 1
  [[ -f "$VPS_RECOVERY_WORK/release/compose.yaml" && -f "$VPS_RECOVERY_WORK/release/ops/vps/compose.yaml" ]] || exit 1
  [[ -f "$VPS_RECOVERY_WORK/config/env" && -f "$VPS_RECOVERY_WORK/state/install.json" && ! -e "$VPS_RECOVERY_WORK/state/install.lock" ]] || exit 1
  release="$VPS_PREFIX/releases/$VPS_RECOVERY_SHA"
  if [[ -e "$release" || -L "$release" ]]; then
    vps_recovery_path "$release" || exit 1
    # Immutable releases cannot be replaced with a different tree under one SHA.
    tar --compare --file "$source/release.tar" -C "$release" >/dev/null || exit 1
    tar -tf "$source/release.tar" | sed -e 's#^\./##' -e 's#/$##' -e 's#^$#.#' | sort > "$VPS_RECOVERY_WORK/archived-paths" || exit 1
    (cd "$release" && find . -print) | sed 's#^\./##' | sort > "$VPS_RECOVERY_WORK/installed-paths" || exit 1
    cmp -s "$VPS_RECOVERY_WORK/archived-paths" "$VPS_RECOVERY_WORK/installed-paths" || exit 1
  fi
  # No volume/database/config changes until validation and image loading finish.
  phase=images
  vps_docker image load < "$source/images.tar" >/dev/null || exit 1
  for ((i=0; i<${#VPS_RECOVERY_IMAGES[@]}; i++)); do
    [[ "$(vps_docker image inspect --format '{{.Id}}' "${VPS_RECOVERY_IDS[i]}")" == "${VPS_RECOVERY_IDS[i]}" ]] || exit 1
    # Retain saved tags too. A Compose ID overlay handles digest-only images.
    if [[ "${VPS_RECOVERY_IMAGES[i]}" != *@* && "${VPS_RECOVERY_IMAGES[i]}" != sha256:* ]]; then
      vps_docker image tag "${VPS_RECOVERY_IDS[i]}" "${VPS_RECOVERY_IMAGES[i]}" || exit 1
    fi
  done
  for key in primary cache queue cable; do
    database=navishai_lab_production
    [[ "$key" == primary ]] || database+="_$key"
    vps_recovery_dump_check "$source/$key.dump" "$database" "$VPS_RECOVERY_PG_IMAGE" || exit 1
  done
  phase=files
  # Labels are not enough: reject foreign mounts before taking the project down
  # or deleting config/volume contents. Missing volumes are rebuilt later.
  for key in lab_postgres_data rails_storage caddy_data caddy_config; do
    if vps_docker volume inspect "${VPS_PROJECT}_$key" >/dev/null 2>&1; then
      vps_recovery_volume "$key" >/dev/null || exit 1
    fi
  done
  running="$(vps_compose ps --status running --services)" || exit 1
  if grep -qx postgres <<< "$running"; then
    vps_recovery_clients_stopped || exit 1
  fi
  vps_compose down >/dev/null || exit 1
  if [[ ! -e "$release" ]]; then mv -T -- "$VPS_RECOVERY_WORK/release" "$release" || exit 1; fi
  # Restore the exact contents; preserve directory paths and the active lock inode.
  find "$VPS_CONFIG" -mindepth 1 -delete || exit 1
  find "$VPS_STATE" -mindepth 1 ! -path "$VPS_STATE/install.lock" -delete || exit 1
  tar --numeric-owner --same-owner --same-permissions -xf "$source/config.tar" -C "$VPS_CONFIG" || exit 1
  tar --numeric-owner --same-owner --same-permissions -xf "$source/state.tar" -C "$VPS_STATE" || exit 1
  ln -s "releases/$VPS_RECOVERY_SHA" "$VPS_RECOVERY_WORK/current" || exit 1
  mv -T -- "$VPS_RECOVERY_WORK/current" "$VPS_PREFIX/current" || exit 1
  VPS_RELEASE="$release"
  VPS_IMAGE="navishai-reset:$VPS_RECOVERY_SHA"
  vps_load_env >/dev/null || exit 1
  # Docker save/load does not retain upstream RepoDigests. The parent always
  # includes this final private overlay; upgrade removes it before candidate use.
  (for ((i=0; i<${#VPS_RECOVERY_IMAGES[@]}; i++)); do
    printf '%s\t%s\n' "${VPS_RECOVERY_SERVICES[i]}" "${VPS_RECOVERY_IDS[i]}" || exit 1
  done) | jq -Rn '{services: ([inputs | split("\t") | {key: .[0], value: {image: .[1]}}] | from_entries)}' \
    > "$VPS_STATE/recovery-images.yaml" || exit 1
  for ((i=0; i<${#VPS_RECOVERY_IMAGES[@]}; i++)); do
    [[ "$(vps_recovery_image_ref "${VPS_RECOVERY_SERVICES[i]}")" == "${VPS_RECOVERY_IDS[i]}" ]] || exit 1
  done
  phase=volumes
  for key in rails_storage caddy_data caddy_config; do
    vps_recovery_volume_restore "$key" "$VPS_RECOVERY_PG_IMAGE" "$source/$key.tar" || exit 1
  done
  phase=databases
  vps_compose up -d --no-deps --pull never postgres >/dev/null || exit 1
  vps_recovery_pg_ready || exit 1
  # Recreated container env uses the restored private config. Do not copy a
  # cluster-global admin definition or put a password on a command line.
  vps_recovery_sql postgres <<'SQL' || exit 1
\getenv admin_password POSTGRES_PASSWORD
ALTER ROLE navishai_admin PASSWORD :'admin_password';
SQL
  vps_recovery_volume lab_postgres_data >/dev/null || exit 1
  vps_recovery_clients_stopped || exit 1
  # Only the four fixed DBs are dropped. A new client causes refusal, not forced
  # termination; normal web/jobs/proxy remain stopped throughout recovery.
  for key in primary cache queue cable; do
    database=navishai_lab_production
    [[ "$key" == primary ]] || database+="_$key"
    printf 'DROP DATABASE IF EXISTS %s;\n' "$database" | vps_recovery_sql postgres || exit 1
    vps_recovery_pg pg_restore -U navishai_admin -d postgres --create --exit-on-error < "$source/$key.dump" || exit 1
    vps_recovery_database_check "$database" || exit 1
  done
  phase=roles
  vps_recovery_roles_restore "$source/roles.tsv" || exit 1
  vps_recovery_roles_dump > "$VPS_RECOVERY_WORK/roles-restored.tsv" || exit 1
  cmp -s "$source/roles.tsv" "$VPS_RECOVERY_WORK/roles-restored.tsv" || exit 1
  phase=postgres-config
  vps_recovery_pg_config_restore "$VPS_RECOVERY_PG_IMAGE" "$source/postgres-config.tar" || exit 1
  vps_recovery_pg_ready || exit 1
  vps_recovery_stopped || exit 1
  success=1
  # No vps_start: the caller must verify recovery and apply its startup gates.
)

vps_restore() {
  if vps_recovery_restore "$@"; then
    # The filesystem restore runs in a subshell; refresh the caller's code path.
    VPS_RELEASE="$(realpath -e -- "$VPS_PREFIX/current")" || return 1
    VPS_IMAGE="navishai-reset:${VPS_RELEASE##*/}"
    vps_load_env >/dev/null 2>&1 || { vps_stop >/dev/null 2>&1; vps_recovery_error; return 1; }
  else
    return 1
  fi
}
