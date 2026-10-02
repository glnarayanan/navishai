#!/bin/sh
set -eu
: "${POSTGRES_PASSWORD:?set administrator password}"
: "${NAVISHAI_PREPARE_PASSWORD:?set owner password}"
: "${NAVISHAI_DATABASE_PASSWORD:?set runtime password}"
[ "$POSTGRES_USER" = navishai_admin ] || exit 1
[ "$POSTGRES_PASSWORD" != "$NAVISHAI_PREPARE_PASSWORD" ] &&
  [ "$POSTGRES_PASSWORD" != "$NAVISHAI_DATABASE_PASSWORD" ] &&
  [ "$NAVISHAI_PREPARE_PASSWORD" != "$NAVISHAI_DATABASE_PASSWORD" ] || {
    echo 'All three database passwords must differ.' >&2; exit 1;
  }
psql -v ON_ERROR_STOP=1 --username navishai_admin --dbname "$POSTGRES_DB" <<'SQL'
\getenv owner_password NAVISHAI_PREPARE_PASSWORD
\getenv runtime_password NAVISHAI_DATABASE_PASSWORD
CREATE ROLE navishai_setup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'owner_password';
CREATE ROLE navishai LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_password';
ALTER DATABASE navishai_lab_production OWNER TO navishai_setup;
CREATE DATABASE navishai_lab_production_cache OWNER navishai_setup;
CREATE DATABASE navishai_lab_production_queue OWNER navishai_setup;
CREATE DATABASE navishai_lab_production_cable OWNER navishai_setup;
REVOKE ALL ON DATABASE navishai_lab_production, navishai_lab_production_cache, navishai_lab_production_queue, navishai_lab_production_cable FROM PUBLIC;
\connect navishai_lab_production
ALTER SCHEMA public OWNER TO navishai_setup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
\connect navishai_lab_production_cache
ALTER SCHEMA public OWNER TO navishai_setup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
\connect navishai_lab_production_queue
ALTER SCHEMA public OWNER TO navishai_setup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
\connect navishai_lab_production_cable
ALTER SCHEMA public OWNER TO navishai_setup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
