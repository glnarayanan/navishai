#!/bin/sh
set -eu

: "${NAVISHAI_DATABASE_PASSWORD:?set the runtime password}"
: "${POSTGRES_PASSWORD:?set the separate preparation password}"
if [ "$NAVISHAI_DATABASE_PASSWORD" = "$POSTGRES_PASSWORD" ]; then
  echo "Preparation and runtime passwords must differ." >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv runtime_password NAVISHAI_DATABASE_PASSWORD
CREATE ROLE navishai LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_password';
SQL
