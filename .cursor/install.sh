#!/usr/bin/env bash
# Idempotent repository bootstrap for the NavishAI Cloud Agent environment.
# System toolchains (Ruby 3.4.10 via mise, Go 1.27.0, PostgreSQL 15 + pgvector,
# libvips, Chrome) come from the environment snapshot; this script refreshes
# source-derived state only.
set -euo pipefail

export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:/usr/lib/postgresql/15/bin:${PATH}"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== Installing pinned toolchains (mise.toml) =="
mise install

# PostgreSQL must be running so the database can be prepared.
if ! pg_isready --quiet; then
  sudo pg_ctlcluster 15 main start || true
  for _ in $(seq 1 30); do pg_isready --quiet && break; sleep 1; done
fi

echo "== Installing Ruby gems =="
bundle check || bundle install

echo "== Fetching Go modules =="
go mod download

echo "== Preparing development and test databases =="
bin/rails db:prepare
RAILS_ENV=test bin/rails db:prepare

echo "== Clearing logs and tempfiles =="
bin/rails log:clear tmp:clear

echo "Install complete."
