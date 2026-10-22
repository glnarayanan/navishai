#!/usr/bin/env ruby
# Explicit orb-only proof. No arguments, shared daemon, real credential or provider.
require "etc"
require "open3"
require "securerandom"
require "shellwords"
require "tmpdir"

abort "Usage: ruby test/support/vps_recovery_disposable.rb (no arguments)" unless ARGV.empty?
root = File.expand_path("../..", __dir__)
directory = Dir.mktmpdir("vr-")
service = "vr-#{SecureRandom.hex(4)}"
secrets = Array.new(3) { SecureRandom.hex(24) }
environment = { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"),
  "USER" => Etc.getpwuid.name, "LOGNAME" => Etc.getpwuid.name }
run = lambda do |*command, input: ""|
  output, status = Open3.capture2e(environment, *command, stdin_data: input, unsetenv_others: true)
  safe = secrets.reduce(output) { |text, secret| text.gsub(secret, "<REDACTED>") }
  raise "#{command.first} failed: #{safe}" unless status.success?
  output
end
sudo = ->(*command, **options) { run.call("sudo", "-n", *command, **options) }
docker = ->(*command, **options) { sudo.call("docker", "--config", directory, "--host", "unix://#{directory}/docker.sock", *command, **options) }
started = false
begin
  sudo.call("chmod", "700", directory)
  sudo.call("chown", "0:0", directory)
  sudo.call("mkdir", "#{directory}/config", "#{directory}/state", "#{directory}/backups", "#{directory}/releases")
  sudo.call("chmod", "700", "#{directory}/config", "#{directory}/state", "#{directory}/backups")
  sudo.call("tee", "#{directory}/daemon.json", input: "{}")
  # The daemon has no bridge, port publication or host firewall/forwarding writes.
  command = [ "sudo", "-n", "dockerd", "--config-file=#{directory}/daemon.json", "--host=unix://#{directory}/docker.sock", "--data-root=#{directory}/data",
    "--exec-root=#{directory}/exec", "--pidfile=#{directory}/daemon.pid", "--storage-driver=vfs", "--bridge=none",
    "--iptables=false", "--ip6tables=false", "--ip-forward=false", "--ip-masq=false", "--userland-proxy=false" ]
  run.call("amp", "orb", "service", "start", service, "--command", Shellwords.join(command))
  started = true
  deadline = Time.now + 120
  loop do
    begin
      break if docker.call("info", "--format", "{{.DockerRootDir}}").strip == "#{directory}/data"
    rescue RuntimeError
      raise "Private daemon did not start: #{run.call('amp', 'orb', 'service', 'logs', service)}" if Time.now > deadline
      sleep 1
    end
  end
  cli = "#{directory}/compose"
  url = "https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-x86_64"
  sudo.call("curl", "-fsSL", url, "-o", cli)
  expected = run.call("curl", "-fsSL", "#{url}.sha256").split.first
  raise "Compose checksum mismatch" unless expected.match?(/\A[0-9a-f]{64}\z/) && sudo.call("sha256sum", cli).split.first == expected
  sudo.call("chmod", "700", cli)
  # The release under test starts on the last PostgreSQL 16 pin, then moves to 18.
  postgres = "postgres:16@sha256:a902560563d3a5661228585f53474c5065e7f273b21ffd77e555a8b5682c5690"
  postgres18 = "postgres:18@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6"
  docker.call("pull", postgres)
  docker.call("pull", postgres18)
  image = docker.call("image", "inspect", "--format", "{{.Id}}", postgres).strip
  image18 = docker.call("image", "inspect", "--format", "{{.Id}}", postgres18).strip
  old = "6c9fa890127c7cbfac59b810f68ebd9b3bb77603"
  newer = "2" * 40
  docker.call("tag", image, "navishai-reset:#{old}")
  shell = <<~BASH
    set -euo pipefail
    trap 'printf "Disposable proof failed at shell line %s\\n" "$LINENO" >&2' ERR
    umask 077
    ROOT=#{Shellwords.escape(directory)}
    source #{Shellwords.escape(File.join(root, "ops/vps/recovery.sh"))}
    VPS_PREFIX="$ROOT/installation"
    VPS_CONFIG="$ROOT/config"
    VPS_STATE="$ROOT/state"
    VPS_PROJECT=navishai-reset
    OLD=#{old}
    NEW=#{newer}
    PG_IMAGE=#{postgres}
    PG_ID=#{image}
    PG18_ID=#{image18}
    PG18_RELEASE=#{"3" * 40}
    mkdir -p "$VPS_PREFIX/releases/$OLD/ops/vps"
    VPS_RELEASE="$VPS_PREFIX/releases/$OLD"
    ln -s "releases/$OLD" "$VPS_PREFIX/current"
    echo "$OLD" > "$VPS_RELEASE/SOURCE_COMMIT"
    echo old > "$VPS_RELEASE/code"
    printf 'NAVISHAI_POSTGRES_PASSWORD=%s\nNAVISHAI_PREPARE_PASSWORD=%s\nNAVISHAI_DATABASE_PASSWORD=%s\n' \
      #{Shellwords.escape(secrets[0])} #{Shellwords.escape(secrets[1])} #{Shellwords.escape(secrets[2])} > "$VPS_CONFIG/env"
    echo '{"project":"navishai-reset","release":"'$OLD'"}' > "$VPS_STATE/install.json"
    echo retained-bootstrap > "$VPS_STATE/bootstrap"
    touch "$VPS_STATE/install.lock"
    exec 9>"$VPS_STATE/install.lock"
    flock -n 9
    LOCK_INODE="$(stat -c %i "$VPS_STATE/install.lock")"
    cat > "$VPS_RELEASE/compose.yaml" <<'YAML'
    x-owned: &owned
      labels:
        com.navishai.owner: navishai-reset
    services:
      postgres:
        <<: *owned
        image: #{postgres}
        network_mode: none
        environment:
          POSTGRES_USER: navishai_admin
          POSTGRES_DB: postgres
          POSTGRES_PASSWORD: ${NAVISHAI_POSTGRES_PASSWORD}
          NAVISHAI_PREPARE_PASSWORD: ${NAVISHAI_PREPARE_PASSWORD}
          NAVISHAI_DATABASE_PASSWORD: ${NAVISHAI_DATABASE_PASSWORD}
        volumes:
          - lab_postgres_data:/var/lib/postgresql/data
          - ./ops/vps/init.sh:/docker-entrypoint-initdb.d/10-roles.sh:ro
      app-net:
        <<: *owned
        image: navishai-reset:#{old}
        network_mode: none
        entrypoint: ["sleep", "infinity"]
      web:
        <<: *owned
        image: navishai-reset:#{old}
        network_mode: service:app-net
        entrypoint: ["sleep", "infinity"]
        volumes: [rails_storage:/rails/storage]
      jobs:
        <<: *owned
        image: navishai-reset:#{old}
        network_mode: service:app-net
        entrypoint: ["sleep", "infinity"]
      proxy:
        <<: *owned
        image: #{postgres}
        network_mode: none
        entrypoint: ["sleep", "infinity"]
        volumes: [caddy_data:/data, caddy_config:/config]
    volumes:
      lab_postgres_data:
        labels: {com.navishai.owner: navishai-reset}
      rails_storage:
        labels: {com.navishai.owner: navishai-reset}
      caddy_data:
        labels: {com.navishai.owner: navishai-reset}
      caddy_config:
        labels: {com.navishai.owner: navishai-reset}
    YAML
    echo 'services: {}' > "$VPS_RELEASE/ops/vps/compose.yaml"
    cat > "$VPS_RELEASE/ops/vps/init.sh" <<'INIT'
    #!/bin/sh
    set -eu
    psql -X -q -v ON_ERROR_STOP=1 -U navishai_admin -d postgres <<'SQL'
    \\getenv prep NAVISHAI_PREPARE_PASSWORD
    \\getenv runtime NAVISHAI_DATABASE_PASSWORD
    CREATE ROLE navishai_setup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'prep';
    CREATE ROLE navishai LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'runtime';
    CREATE ROLE unrelated_role;
    CREATE DATABASE unrelated_database OWNER unrelated_role;
    CREATE DATABASE navishai_lab_production OWNER navishai_setup;
    CREATE DATABASE navishai_lab_production_cache OWNER navishai_setup;
    CREATE DATABASE navishai_lab_production_queue OWNER navishai_setup;
    CREATE DATABASE navishai_lab_production_cable OWNER navishai_setup;
    SQL
    INIT
    chmod 755 "$VPS_PREFIX" "$VPS_PREFIX/releases" "$VPS_RELEASE" "$VPS_RELEASE/ops" "$VPS_RELEASE/ops/vps"
    chmod 644 "$VPS_RELEASE/"*.yaml "$VPS_RELEASE/SOURCE_COMMIT" "$VPS_RELEASE/code" "$VPS_RELEASE/ops/vps/compose.yaml"
    chmod 755 "$VPS_RELEASE/ops/vps/init.sh"
    vps_docker() { docker --config "$ROOT" --host "unix://$ROOT/docker.sock" "$@"; }
    vps_compose() {
      local -a args=(--host "unix://$ROOT/docker.sock" --project-name "$VPS_PROJECT" --env-file "$VPS_CONFIG/env" \
        -f "$VPS_RELEASE/compose.yaml" -f "$VPS_RELEASE/ops/vps/compose.yaml")
      [[ ! -e "$VPS_STATE/recovery-images.yaml" ]] || args+=(-f "$VPS_STATE/recovery-images.yaml")
      "$ROOT/compose" "${args[@]}" "$@"
    }
    vps_stop() { vps_compose stop web jobs proxy >/dev/null; }
    vps_start() { echo 'ERROR: recovery must not start workloads' >&2; return 1; }
    vps_load_env() {
      local key value
      while IFS='=' read -r key value; do
        [[ "$key" =~ ^NAVISHAI_(POSTGRES|PREPARE|DATABASE)_PASSWORD$ ]] || return 1
        export "$key=$value"
      done < "$VPS_CONFIG/env"
    }
    # Kept outside the daemon: the complete-image-loss phase below deletes it.
    vps_docker image save "$PG18_ID" > "$ROOT/postgres18.tar"
    vps_compose up -d --pull never
    for i in {1..60}; do
      if [[ "$(vps_recovery_sql postgres <<< "SELECT 1 FROM pg_roles WHERE rolname = 'navishai';" 2>/dev/null)" == 1 ]]; then break; fi
      sleep 1
    done
    [[ $i -lt 60 ]]
    for key in primary cache queue cable; do
      database=navishai_lab_production
      [[ "$key" == primary ]] || database+="_$key"
      vps_recovery_sql "$database" <<'SQL'
    SET ROLE navishai_setup;
    REVOKE CONNECT, TEMPORARY ON DATABASE :DBNAME FROM PUBLIC;
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    GRANT CONNECT ON DATABASE :DBNAME TO navishai;
    GRANT USAGE ON SCHEMA public TO navishai;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO navishai;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO navishai;
    CREATE TABLE records (id bigserial PRIMARY KEY, marker text);
    INSERT INTO records(marker) VALUES ('asymmetric-first'), ('retained-second');
    SELECT setval('records_id_seq', 47, true);
    CREATE FUNCTION reject_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'immutable fixture'; END $$;
    CREATE TRIGGER fixed BEFORE UPDATE OR DELETE ON records FOR EACH ROW EXECUTE FUNCTION reject_change();
    SQL
      vps_recovery_pg pg_dump -U navishai_admin -d "$database" --format=custom --create > "$ROOT/expected-$key.dump"
    done
    # Independent catalog/content/sequence expectations, not pg_dump file bytes.
    snapshot() {
      vps_recovery_sql "$1" <<'SQL'
    SELECT id,marker FROM records ORDER BY id;
    SELECT last_value,is_called FROM records_id_seq;
    SELECT datdba::regrole,datacl FROM pg_database WHERE datname=current_database();
    SELECT nspowner::regrole,nspacl FROM pg_namespace WHERE nspname='public';
    SELECT relname,relowner::regrole,relacl FROM pg_class WHERE relnamespace='public'::regnamespace ORDER BY relname;
    SELECT defaclrole::regrole,defaclnamespace::regnamespace,defaclobjtype,defaclacl FROM pg_default_acl ORDER BY 1,2,3;
    SQL
    }
    for key in primary cache queue cable; do
      database=navishai_lab_production; [[ "$key" == primary ]] || database+="_$key"
      snapshot "$database" > "$ROOT/expected-$key"
    done
    for key in rails_storage caddy_data caddy_config; do
      vps_docker run --rm --network none --mount "type=volume,src=navishai-reset_$key,dst=/data" \
        --entrypoint sh "$PG_ID" -ec 'umask 077; echo retained-volume > /data/synthetic; chmod 600 /data/synthetic'
    done
    vps_docker run --rm --network none --mount type=volume,src=navishai-reset_rails_storage,dst=/data \
      --entrypoint sh "$PG_ID" -ec 'chown -R 1000:1000 /data'
    vps_backup "$ROOT/backups/good"
    vps_recovery_stopped
    # Reject unrelated DB ACLs and runtime elevation, before capturing anything.
    vps_recovery_sql navishai_lab_production <<'SQL'
    GRANT CONNECT ON DATABASE navishai_lab_production TO unrelated_role;
    SQL
    if vps_backup "$ROOT/backups/foreign"; then exit 1; fi
    [[ ! -e "$ROOT/backups/foreign" ]]
    vps_recovery_sql navishai_lab_production <<'SQL'
    REVOKE CONNECT ON DATABASE navishai_lab_production FROM unrelated_role;
    SQL
    vps_recovery_sql postgres <<'SQL'
    ALTER ROLE navishai BYPASSRLS;
    SQL
    if vps_backup "$ROOT/backups/elevated"; then exit 1; fi
    [[ ! -e "$ROOT/backups/elevated" ]]
    vps_recovery_sql postgres <<'SQL'
    ALTER ROLE navishai NOBYPASSRLS;
    SQL
    # Even a stopped foreign container must prevent volume deletion and DB work.
    foreign="$(vps_docker create --network none --mount type=volume,src=navishai-reset_rails_storage,dst=/data \
      --entrypoint sleep "$PG_ID" infinity)"
    if vps_restore "$ROOT/backups/good"; then exit 1; fi
    snapshot navishai_lab_production > "$ROOT/shared-check"
    cmp "$ROOT/expected-primary" "$ROOT/shared-check"
    vps_docker rm "$foreign" >/dev/null
    vps_docker exec -d "$(vps_compose ps -q postgres)" psql -X -q -U navishai_admin \
      -d navishai_lab_production -c 'SELECT pg_sleep(600);'
    for i in {1..60}; do
      if ! vps_recovery_clients_stopped; then break; fi
      sleep 1
    done
    [[ $i -lt 60 ]]
    if vps_restore "$ROOT/backups/good"; then exit 1; fi
    vps_recovery_sql postgres <<'SQL' >/dev/null
    SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE datname='navishai_lab_production' AND query='SELECT pg_sleep(600);';
    SQL
    for i in {1..60}; do
      if vps_recovery_clients_stopped; then break; fi
      sleep 1
    done
    [[ $i -lt 60 ]]
    snapshot navishai_lab_production > "$ROOT/client-check"
    cmp "$ROOT/expected-primary" "$ROOT/client-check"
    echo 'PASS: real foreign ACL/elevated-role backup refusal; stopped shared-volume user and live DB client refuse restore without changing data.'
    # Real additive candidate migration + changed code/config/storage, then rollback.
    cp -a "$VPS_RELEASE" "$VPS_PREFIX/releases/$NEW"
    sed -i "s/$OLD/$NEW/g" "$VPS_PREFIX/releases/$NEW/compose.yaml"
    echo "$NEW" > "$VPS_PREFIX/releases/$NEW/SOURCE_COMMIT"
    echo candidate > "$VPS_PREFIX/releases/$NEW/code"
    vps_docker tag "$PG_ID" "navishai-reset:$NEW"
    ln -sfn "releases/$NEW" "$VPS_PREFIX/current"
    VPS_RELEASE="$VPS_PREFIX/releases/$NEW"
    vps_recovery_sql navishai_lab_production <<'SQL'
    SET ROLE navishai_setup;
    ALTER TABLE records ADD COLUMN candidate text;
    INSERT INTO records(marker) VALUES ('candidate-only');
    SQL
    vps_recovery_sql postgres <<'SQL'
    ALTER ROLE unrelated_role NOINHERIT CONNECTION LIMIT 17;
    SQL
    while IFS='=' read -r key value; do printf '%s=%s-candidate\\n' "$key" "$value"; done < "$VPS_CONFIG/env" > "$ROOT/candidate-env"
    cp "$ROOT/candidate-env" "$VPS_CONFIG/env"
    vps_load_env
    vps_compose up -d --no-deps --force-recreate --pull never postgres >/dev/null
    vps_recovery_pg_ready
    vps_recovery_sql postgres <<'SQL'
    \\getenv admin_password POSTGRES_PASSWORD
    \\getenv prep NAVISHAI_PREPARE_PASSWORD
    \\getenv runtime NAVISHAI_DATABASE_PASSWORD
    ALTER ROLE navishai_admin PASSWORD :'admin_password';
    ALTER ROLE navishai_setup PASSWORD :'prep';
    ALTER ROLE navishai PASSWORD :'runtime';
    ALTER SYSTEM SET log_min_duration_statement = '1234';
    SQL
    echo candidate > "$VPS_STATE/bootstrap"
    vps_restore "$ROOT/backups/good"
    [[ "$(cat "$VPS_PREFIX/current/code")" == old ]]
    grep -qx retained-bootstrap "$VPS_STATE/bootstrap"
    if grep -q candidate "$VPS_CONFIG/env"; then exit 1; fi
    [[ "$(vps_recovery_sql postgres <<<'SHOW log_min_duration_statement;')" == -1 ]]
    [[ "$(vps_recovery_sql postgres <<<"SELECT rolinherit || ':' || rolconnlimit FROM pg_roles WHERE rolname='unrelated_role';")" == false:17 ]]
    for role in navishai_admin navishai_setup navishai; do
      vps_compose exec -T postgres sh -ec 'case "$1" in navishai_admin) PGPASSWORD="$POSTGRES_PASSWORD";; navishai_setup) PGPASSWORD="$NAVISHAI_PREPARE_PASSWORD";; navishai) PGPASSWORD="$NAVISHAI_DATABASE_PASSWORD";; esac; export PGPASSWORD; exec psql -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d navishai_lab_production' sh "$role" <<'SQL' > "$ROOT/login"
    SELECT current_user;
    SQL
      [[ "$(cat "$ROOT/login")" == "$role" ]]
    done
    [[ "$(stat -c %i "$VPS_STATE/install.lock")" == "$LOCK_INODE" ]]
    VPS_RELEASE="$VPS_PREFIX/releases/$OLD"
    for key in primary cache queue cable; do
      database=navishai_lab_production; [[ "$key" == primary ]] || database+="_$key"
      snapshot "$database" > "$ROOT/restored-$key"
      cmp "$ROOT/expected-$key" "$ROOT/restored-$key"
    done
    echo 'PASS: real candidate schema/code/config/password/server-setting rollback; four exact row/sequence/owner/ACL/default-ACL catalogs, retained lock/bootstrap and unchanged unrelated role.'
    # Remove all containers, all four volumes, all retained images and old code.
    # This simulates local loss; recovery must not rely on tags or RepoDigests.
    vps_compose down --volumes
    rm -rf "$VPS_PREFIX/releases/$OLD"
    ln -sfn "releases/$NEW" "$VPS_PREFIX/current"
    VPS_RELEASE="$VPS_PREFIX/releases/$NEW"
    vps_docker image ls -q | sort -u | xargs -r -n1 docker --config "$ROOT" --host "unix://$ROOT/docker.sock" image rm -f
    [[ -z "$(vps_docker image ls -q)" ]]
    vps_restore "$ROOT/backups/good"
    VPS_RELEASE="$VPS_PREFIX/releases/$OLD"
    for key in primary cache queue cable; do
      database=navishai_lab_production; [[ "$key" == primary ]] || database+="_$key"
      snapshot "$database" > "$ROOT/restored-$key"
      cmp "$ROOT/expected-$key" "$ROOT/restored-$key"
      # Password-authenticated runtime login, exact recovered data and sequence.
      vps_compose exec -T postgres sh -ec 'export PGPASSWORD="$NAVISHAI_DATABASE_PASSWORD"; exec psql -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U navishai -d "$1"' sh "$database" <<'SQL' > "$ROOT/runtime-$key"
    SELECT current_user;
    SELECT string_agg(marker,',' ORDER BY id) FROM records;
    INSERT INTO records(marker) VALUES ('post-recovery') RETURNING id;
    SQL
      printf 'navishai\nasymmetric-first,retained-second\n48\n' > "$ROOT/runtime-expected"
      cmp "$ROOT/runtime-expected" "$ROOT/runtime-$key"
      for sql in 'SET ROLE navishai_setup' 'SET ROLE navishai_admin' 'CREATE TABLE forbidden(id integer)' 'ALTER TABLE records DISABLE TRIGGER ALL' "UPDATE records SET marker='forbidden'"; do
        if printf '%s;\n' "$sql" | vps_compose exec -T postgres sh -ec 'export PGPASSWORD="$NAVISHAI_DATABASE_PASSWORD"; exec psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U navishai -d "$1"' sh "$database" >/dev/null 2>&1; then exit 1; fi
      done
      vps_recovery_sql "$database" <<'SQL'
    SET ROLE navishai_setup;
    CREATE TABLE future_records(id bigserial PRIMARY KEY, marker text);
    SQL
      vps_compose exec -T postgres sh -ec 'export PGPASSWORD="$NAVISHAI_DATABASE_PASSWORD"; exec psql -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U navishai -d "$1"' sh "$database" <<'SQL' > "$ROOT/future-$key"
    INSERT INTO future_records(marker) VALUES ('default grants retained') RETURNING id;
    SQL
      [[ "$(cat "$ROOT/future-$key")" == 1 ]]
    done
    for key in rails_storage caddy_data caddy_config; do
      [[ "$(vps_docker run --rm --network none --mount "type=volume,src=navishai-reset_$key,dst=/data,readonly" --entrypoint cat "$PG_ID" /data/synthetic)" == retained-volume ]]
    done
    [[ "$(vps_docker run --rm --network none --mount type=volume,src=navishai-reset_rails_storage,dst=/data,readonly --entrypoint stat "$PG_ID" -c '%u:%g:%a' /data/synthetic)" == 1000:1000:600 ]]
    vps_recovery_stopped
    echo 'PASS: fresh PG volume/roles, retained images reloaded after complete image loss, storage/certificate bytes and storage ownership; real runtime passwords, sequences, default ACLs and 20 denials.'
    # PostgreSQL 16 -> 18, as the first 18 upgrade runs it: writers stopped,
    # backup on 16, an 18 release on a new volume, migrate, verify. The 16 volume
    # is never mounted by 18 and must keep its exact files.
    vps_docker image load < "$ROOT/postgres18.tar" >/dev/null
    for key in primary cache queue cable; do
      database=navishai_lab_production; [[ "$key" == primary ]] || database+="_$key"
      snapshot "$database" > "$ROOT/pre18-$key"
    done
    database_oids() { vps_recovery_sql postgres <<<"SELECT string_agg(datname || '=' || oid, ',' ORDER BY datname) FROM pg_database WHERE datname LIKE 'navishai_lab_production%';"; }
    database_oids > "$ROOT/oids16"
    vps_backup "$ROOT/backups/pre18"
    vps_recovery_stopped
    vps_compose stop postgres >/dev/null
    legacy_tree() {
      vps_docker run --rm --network none --mount type=volume,src=navishai-reset_lab_postgres_data,dst=/data,readonly \
        --entrypoint sh "$PG_ID" -ec 'cd /data && find . -type f -exec sha256sum {} + | sort'
    }
    legacy_tree > "$ROOT/legacy-before"
    cp -a "$VPS_PREFIX/releases/$OLD" "$VPS_PREFIX/releases/$PG18_RELEASE"
    sed -i -e "s|$PG_IMAGE|$PG18_ID|" -e "s|navishai-reset:$OLD|navishai-reset:$PG18_RELEASE|" \
      -e 's|lab_postgres_data:/var/lib/postgresql/data|lab_postgres18_data:/var/lib/postgresql|' \
      -e 's|^  lab_postgres_data:|  lab_postgres18_data:|' "$VPS_PREFIX/releases/$PG18_RELEASE/compose.yaml"
    echo "$PG18_RELEASE" > "$VPS_PREFIX/releases/$PG18_RELEASE/SOURCE_COMMIT"
    vps_docker tag "$PG_ID" "navishai-reset:$PG18_RELEASE"
    ln -sfn "releases/$PG18_RELEASE" "$VPS_PREFIX/current"
    VPS_RELEASE="$VPS_PREFIX/releases/$PG18_RELEASE"
    rm -f "$VPS_STATE/recovery-images.yaml"
    vps_compose up -d --no-deps --pull never postgres >/dev/null
    for i in {1..60}; do
      if [[ "$(vps_recovery_sql postgres <<< "SELECT 1 FROM pg_roles WHERE rolname = 'navishai';" 2>/dev/null)" == 1 ]]; then break; fi
      sleep 1
    done
    [[ $i -lt 60 ]]
    [[ "$(vps_recovery_postgres_state)" == pending ]]
    vps_recovery_migrate "$ROOT/backups/pre18"
    [[ "$(vps_recovery_postgres_state)" == migrated ]]
    [[ "$(vps_recovery_sql postgres <<<'SHOW server_version_num;')" == 18???? ]]
    [[ "$(vps_recovery_pg_layout)" == "lab_postgres18_data 18/docker" ]]
    check_pre18() {
      for key in primary cache queue cable; do
        database=navishai_lab_production; [[ "$key" == primary ]] || database+="_$key"
        snapshot "$database" > "$ROOT/now-$key"
        cmp "$ROOT/pre18-$key" "$ROOT/now-$key"
      done
      for role in navishai_admin navishai_setup navishai; do
        vps_compose exec -T postgres sh -ec 'case "$1" in navishai_admin) PGPASSWORD="$POSTGRES_PASSWORD";; navishai_setup) PGPASSWORD="$NAVISHAI_PREPARE_PASSWORD";; navishai) PGPASSWORD="$NAVISHAI_DATABASE_PASSWORD";; esac; export PGPASSWORD; exec psql -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$1" -d navishai_lab_production' sh "$role" <<'SQL' > "$ROOT/login"
    SELECT current_user;
    SQL
        [[ "$(cat "$ROOT/login")" == "$role" ]]
      done
    }
    check_pre18
    legacy_tree > "$ROOT/legacy-after"
    cmp "$ROOT/legacy-before" "$ROOT/legacy-after"
    echo 'PASS: real PostgreSQL 16 backup migrated into a fresh 18 cluster on a new volume; four exact row/sequence/owner/ACL/default-ACL catalogs, three password logins, role and server-file parity; 16 volume files byte-identical.'
    # Backup and restore keep working on the 18 layout.
    vps_backup "$ROOT/backups/on18"
    vps_recovery_sql navishai_lab_production <<'SQL'
    SET ROLE navishai_setup;
    INSERT INTO records(marker) VALUES ('after-18-backup');
    SQL
    vps_recovery_sql postgres <<<"ALTER SYSTEM SET log_min_duration_statement = '4321';"
    vps_restore "$ROOT/backups/on18"
    VPS_RELEASE="$VPS_PREFIX/releases/$PG18_RELEASE"
    [[ "$(vps_recovery_pg_layout)" == "lab_postgres18_data 18/docker" ]]
    [[ "$(vps_recovery_sql postgres <<<'SHOW log_min_duration_statement;')" == -1 ]]
    [[ "$(vps_recovery_postgres_state)" == migrated ]]
    check_pre18
    echo 'PASS: PostgreSQL 18 backup/restore round trip: rows, server setting and migration marker return to the backup.'
    # Rollback: the pre-migration backup brings back the 16 release, image and
    # the untouched 16 volume. Same database OIDs prove nothing was recreated.
    vps_restore "$ROOT/backups/pre18"
    VPS_RELEASE="$VPS_PREFIX/releases/$OLD"
    [[ "$(cat "$VPS_PREFIX/current/code")" == old ]]
    [[ "$(vps_recovery_sql postgres <<<'SHOW server_version_num;')" == 16???? ]]
    [[ "$(vps_recovery_pg_layout)" == "lab_postgres_data ." ]]
    [[ "$(database_oids)" == "$(cat "$ROOT/oids16")" ]]
    check_pre18
    vps_docker volume inspect navishai-reset_lab_postgres18_data >/dev/null
    vps_recovery_stopped
    echo 'PASS: rollback to the 16 image on the untouched 16 volume: same database OIDs and catalogs, 18 volume retained, writers stopped.'
  BASH
  # Write generated credentials only to private stdin/file, not shell argv.
  sudo.call("tee", "#{directory}/proof.sh", input: shell)
  sudo.call("chmod", "600", "#{directory}/proof.sh")
  output = sudo.call("bash", "#{directory}/proof.sh")
  puts output.lines.grep(/^PASS:/)
  puts "LIMIT: real PostgreSQL 16/18 Docker recovery with synthetic code/writer/proxy stand-ins; no Rails boot, public TLS, network gate, PITR, encryption or live-host claim."
ensure
  # No daemon resource can escape its generated data-root. Stop before deleting it.
  stopped = !started
  if started
    begin
      containers = docker.call("ps", "-aq").split
      docker.call("rm", "-f", *containers) unless containers.empty?
    rescue => error
      warn "Private container cleanup failed: #{error.message}"
    end
    begin
      run.call("amp", "orb", "service", "stop", service)
      stopped = true
    rescue => error
      warn "Cleanup failed for exact service #{service}: #{error.message}"
    end
  end
  if stopped
    sudo.call("findmnt", "-rn", "-o", "TARGET").lines.map(&:strip).select { |path| path.start_with?("#{directory}/exec/netns/") }.each do |path|
      sudo.call("umount", "--", path)
    end
    sudo.call("rm", "-rf", "--", directory)
    puts "CLEAN: owned private daemon, containers, volumes, images, archives and test secrets removed."
  else
    warn "Retained private directory: #{directory}"
  end
end
