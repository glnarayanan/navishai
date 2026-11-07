#!/usr/bin/env bash
# Root-only, disposable command double. No Docker socket or application DB access.
set -euo pipefail
[[ $EUID == 0 ]] || exit 1
source "$RECOVERY_SOURCE"
ROOT="$(mktemp -d /tmp/vr-mock.XXXXXXXX)"
trap 'rm -rf -- "$ROOT"' EXIT
umask 077
VPS_PREFIX="$ROOT/opt/navishai-reset"
VPS_CONFIG="$ROOT/etc/navishai-reset"
VPS_STATE="$ROOT/var/lib/navishai-reset"
VPS_PROJECT=navishai-reset
OLD=6c9fa890127c7cbfac59b810f68ebd9b3bb77603
NEW=2222222222222222222222222222222222222222
VPS_RELEASE="$VPS_PREFIX/releases/$OLD"
mkdir -p "$VPS_RELEASE/ops/vps" "$VPS_CONFIG" "$VPS_STATE" "$ROOT/backups" "$ROOT/volumes" "$ROOT/databases"
printf '%s\n' "$OLD" > "$VPS_RELEASE/SOURCE_COMMIT"
echo 'old synthetic code' > "$VPS_RELEASE/code"
echo 'services: {}' > "$VPS_RELEASE/compose.yaml"
echo 'services: {}' > "$VPS_RELEASE/ops/vps/compose.yaml"
ln -s "releases/$OLD" "$VPS_PREFIX/current"
echo 'synthetic-secret-never-print' > "$VPS_CONFIG/env"
echo '{"project":"navishai-reset"}' > "$VPS_STATE/install.json"
echo 'synthetic-bootstrap-state' > "$VPS_STATE/bootstrap"
touch "$VPS_STATE/install.lock" "$ROOT/log"
LOCK_INODE="$(stat -c %i "$VPS_STATE/install.lock")"
PG_ID="sha256:$(printf '1%.0s' {1..64})"
APP_ID="sha256:$(printf '2%.0s' {1..64})"
PROXY_ID="sha256:$(printf '3%.0s' {1..64})"
NET_ID="sha256:$(printf '4%.0s' {1..64})"
printf 'navishai\tSCRAM-SHA-256$4096:c2FsdA==$c3RvcmVk:c2VydmVy\tfalse\tfalse\tfalse\tfalse\tfalse\ttrue\t-1\nnavishai_setup\tSCRAM-SHA-256$4096:b3RoZXI=$c3RvcmVk:c2VydmVy\tfalse\tfalse\tfalse\tfalse\tfalse\ttrue\t-1\n' > "$ROOT/roles.tsv"
for key in rails_storage caddy_data caddy_config; do
  mkdir "$ROOT/volumes/$key"
  printf 'synthetic-%s-old\n' "$key" > "$ROOT/volumes/$key/value"
done
# MOCK_PG_MAJOR=16 models a release before PostgreSQL 18 (cluster at the root of
# lab_postgres_data); the default models 18 (18/docker inside lab_postgres18_data).
MOCK_PG_MAJOR="${MOCK_PG_MAJOR:-18}"
mock_pg_files() {
  if [[ "$MOCK_PG_MAJOR" == 16 ]]; then echo "$ROOT/volumes/lab_postgres_data"
  else echo "$ROOT/volumes/lab_postgres18_data/18/docker"; fi
}
# Switch the running server's major; a layout seen for the first time gets that
# major's own fresh server files, as initdb would write them.
mock_pg_switch() {
  MOCK_PG_MAJOR="$1"
  [[ ! -d "$(mock_pg_files)" ]] || return 0
  mkdir -p "$(mock_pg_files)"
  for key in postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf; do
    echo "synthetic-postgres-config-$1" > "$(mock_pg_files)/$key"
  done
}
mock_pg_switch "$MOCK_PG_MAJOR"
for key in primary cache queue cable; do
  database=navishai_lab_production
  [[ "$key" == primary ]] || database+="_$key"
  printf '%s\n' "$database" > "$ROOT/databases/$database"
done

vps_stop() { echo stop >> "$ROOT/log"; rm -f "$ROOT/running"; }
vps_start() { echo start >> "$ROOT/log"; touch "$ROOT/running"; }
vps_load_env() { echo load-env >> "$ROOT/log"; }

mock_id() {
  case "$1" in
    *postgres*|"$PG_ID") echo "$PG_ID" ;;
    *proxy*|"$PROXY_ID") echo "$PROXY_ID" ;;
    *app-net*|"$NET_ID") echo "$NET_ID" ;;
    *) echo "$APP_ID" ;;
  esac
}

vps_compose() {
  echo "compose $*" >> "$ROOT/log"
  case "$1" in
    ps)
      if [[ "$*" == *--services* ]]; then
        echo postgres
        [[ ! -f "$ROOT/running" ]] || echo web
      else
        printf 'container-%s\n' "${@: -1}"
      fi ;;
    config)
      if [[ -e "$VPS_STATE/recovery-images.yaml" ]]; then
        cat "$VPS_STATE/recovery-images.yaml"
      else
        jq -n --arg app "navishai-reset:${VPS_RELEASE##*/}" '{services: {postgres: {image: "postgres:synthetic"}, web: {image: $app}, jobs: {image: $app}, proxy: {image: "proxy:synthetic"}, "app-net": {image: "app-net:synthetic"}}}'
      fi ;;
    exec)
      shift 3
      if [[ "$1" == pg_dump ]]; then
        database="$5"
        [[ "${FAIL_STEP:-}" != "dump-$database" ]] || { echo synthetic-secret-never-print >&2; return 1; }
        cat "$ROOT/databases/$database"
      elif [[ "$1" == pg_restore ]]; then
        read -r database
        [[ "${FAIL_STEP:-}" != "restore-$database" ]] || { echo synthetic-secret-never-print >&2; return 1; }
        echo restored > "$ROOT/databases/$database"
      elif [[ "$1" == psql ]]; then
        sql="$(cat)"
        if [[ "$sql" == *'SHOW listen_addresses'* ]]; then echo '*'
        elif [[ "$sql" == *"current_setting('data_directory');"* ]]; then
          if [[ "$MOCK_PG_MAJOR" == 16 ]]; then echo 16:/var/lib/postgresql/data
          else echo 18:/var/lib/postgresql/18/docker; fi
        elif [[ "$sql" == *'FROM pg_authid'* ]]; then cat "$ROOT/roles.tsv"
        elif [[ "$sql" == *'FROM pg_shdepend'* ]]; then echo t
        elif [[ "$sql" == *'FROM pg_stat_activity'* ]]; then
          [[ "${FAIL_STEP:-}" == foreign-client ]] && echo f || echo t
        elif [[ "$sql" == *"current_setting('config_file')"* ]]; then echo t
        fi
      fi ;;
    down|up|stop) ;;
    *) return 1 ;;
  esac
}

vps_docker() {
  echo "docker $*" >> "$ROOT/log"
  if [[ "$1" == inspect ]]; then
    if [[ "$*" == *'.Config.Labels'* ]]; then
      if [[ "${FAIL_STEP:-}" == foreign-user ]]; then
        echo foreign/foreign/web
      else
        echo navishai-reset/navishai-reset/web
      fi
    else
      mock_id "${@: -1}"
    fi
  elif [[ "$1" == ps ]]; then
    [[ "${FAIL_STEP:-}" == foreign-user || "${FAIL_STEP:-}" == forged-user ]] && echo impostor || :
  elif [[ "$1 $2" == 'image inspect' ]]; then
    mock_id "${@: -1}"
  elif [[ "$1 $2" == 'image save' ]]; then
    tar --format=ustar -cf - -C "$ROOT" roles.tsv
  elif [[ "$1 $2" == 'image load' ]]; then
    cat > /dev/null
    [[ "${FAIL_STEP:-}" != load ]] || return 1
  elif [[ "$1 $2" == 'image tag' ]]; then
    :
  elif [[ "$1 $2" == 'volume ls' ]]; then
    [[ "${FAIL_STEP:-}" != volume-ls ]] || return 1
    [[ ! -d "$ROOT/volumes/lab_postgres_data" ]] || echo navishai-reset_lab_postgres_data
  elif [[ "$1 $2" == 'volume inspect' ]]; then
    key="${@: -1}"; key="${key#navishai-reset_}"
    [[ "${FAIL_STEP:-}" != foreign-volume ]] || { echo foreign/rails_storage; return; }
    case "${FAIL_STEP:-}" in
      foreign-owner) echo "local/null/navishai-reset/$key/foreign" ;;
      remote-driver) echo "nfs/null/navishai-reset/$key/navishai-reset" ;;
      bind-options) echo "local/{\"device\":\"/etc\",\"o\":\"bind\"}/navishai-reset/$key/navishai-reset" ;;
      *) echo "local/null/navishai-reset/$key/navishai-reset" ;;
    esac
  elif [[ "$1" == run ]]; then
    local mount= entry= argument previous= directory=
    for argument in "$@"; do
      [[ "$previous" != --mount ]] || mount="$argument"
      [[ "$previous" != --entrypoint ]] || entry="$argument"
      [[ "$previous" != -C ]] || directory="${argument#/data}"
      previous="$argument"
    done
    if [[ "$entry" == pg_restore ]]; then
      [[ "$*" == *' -i '* ]] || return 1
      read -r database
      printf '1; 0 1 DATABASE - %s navishai_setup\n' "$database"
    else
      key="${mount#*src=navishai-reset_}"; key="${key%%,*}"
      if [[ "$entry" == tar ]]; then
        [[ "${FAIL_STEP:-}" != "volume-$key" ]] || return 1
        if [[ "$key" == lab_postgres_data || "$key" == lab_postgres18_data ]]; then
          tar --format=ustar --owner=999 --group=999 -cf - -C "$ROOT/volumes/$key$directory" postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf
        else
          tar --format=ustar -cf - -C "$ROOT/volumes/$key" .
        fi
      elif [[ "$entry" == sh ]]; then
        [[ "$*" == *' -i '* ]] || return 1
        [[ "${FAIL_STEP:-}" != "restore-volume-$key" ]] || return 1
        if [[ "$key" == lab_postgres_data || "$key" == lab_postgres18_data ]]; then
          # Server files only, into the layout's data directory (the last argument).
          tar --same-owner --same-permissions -xf - -C "$ROOT/volumes/$key/${@: -1}"
        else
          find "$ROOT/volumes/$key" -mindepth 1 -delete
          tar --same-owner --same-permissions -xf - -C "$ROOT/volumes/$key"
        fi
      else return 1
      fi
    fi
  else
    return 1
  fi
}

rehash() { (cd "$ROOT/backups/good" && vps_recovery_checksums > CHECKSUMS); }
good_backup() { vps_backup "$ROOT/backups/good"; }
assert_stopped() { [[ ! -e "$ROOT/running" ]]; ! grep -qx start "$ROOT/log"; }
