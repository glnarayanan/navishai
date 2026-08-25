#!/usr/bin/env bash
# Per-boot reconciliation for the NavishAI Cloud Agent environment.
# Starts the PostgreSQL 15 cluster (its data and databases are baked into the
# environment snapshot) and returns once the server accepts connections.
set -euo pipefail

export PATH="/usr/lib/postgresql/15/bin:${PATH}"

if ! pg_isready --quiet; then
  sudo pg_ctlcluster 15 main start || true
fi

for _ in $(seq 1 30); do
  if pg_isready --quiet; then
    echo "PostgreSQL is ready."
    exit 0
  fi
  sleep 1
done

echo "PostgreSQL did not become ready in time." >&2
exit 1
