# Backup, restore, and upgrades

PostgreSQL is authoritative for tenant, business, audit, policy, memory, and execution-ledger data. A complete backup also needs uploaded file bytes, runner admission state, Supermemory state, deployment configuration references, and the secret store managed outside NavishAI.

Do not copy a live local file or Supermemory store. Stop every writer before taking those archives. Keep backup encryption, access control, expiry, and off-site copies in the operator's backup system. NavishAI archives contain customer content even when the files have opaque names.

## Compose backup

Run from the checked-out release root:

```sh
ops/compose/backup /secure/backups/navishai-2026-08-24
ops/compose/verify_backup /secure/backups/navishai-2026-08-24
```

The backup command starts PostgreSQL if needed, stops jobs, web, and the runner, dumps all four databases, then stops Supermemory while copying its state. It restarts the application after the snapshot. If any step fails, it tries to restart the application and leaves the partial directory for diagnosis; never treat that directory as a backup.

The `navishai-backup-v1` directory contains:

- custom-format dumps for primary, cache, queue, and cable PostgreSQL databases;
- tar archives for Rails local storage, runner state, and Supermemory state;
- the exact container image references;
- the source Git revision and SHA-256 digests for `compose.yaml` and `.env`;
- environment key names, but no environment values;
- SHA-256 checksums for every archive member.

Back up `.env`, runner TLS keys, SMTP and integration secrets, runtime subscription credentials, and any external object-store credentials in the host's secret manager. The archive records the `.env` digest so an operator can match the separately protected copy without exposing it.

`verify_backup` checks every checksum, uses the exact PostgreSQL image recorded in the archive to parse each database dump, and reads every tar directory. It does not need a running database or application configuration, but Docker may need to pull that pinned image. Verification does not prove restore. Run a restore test on a schedule and before an upgrade.

## Restore and restore test

Restore destroys the target Compose project's databases and persistent application state. It requires an exact flag:

```sh
ops/compose/restore /secure/backups/navishai-2026-08-24 --confirm-destroy
```

The command verifies first, stops application services, recreates all four databases, restores the three state volumes, and starts the application. If it fails after destruction starts, it leaves application services stopped. Fix the cause and restart the full restore rather than serving mixed state.

Test a restore in an isolated project with an isolated `.env`, host port, and secret set:

```sh
export COMPOSE_PROJECT_NAME=navishai-restore-test
export COMPOSE_ENV_FILES=.env.restore-test
export NAVISHAI_HTTP_PORT=3100
docker compose up -d --wait postgres
ops/compose/restore /secure/backups/navishai-2026-08-24 --confirm-destroy
curl --fail --head http://127.0.0.1:3100/up
```

The direct health check returns an HTTPS redirect and proves that Rails has booted. Use a test hostname and TLS proxy for browser checks. Sign in, open one retained attachment, inspect one audit chain, and run a Memory search. If Supermemory state cannot be restored, use the Manager/Admin/Owner **Rebuild index** action after PostgreSQL and files are healthy. That rebuild uses stable Memory keys and PostgreSQL content; do not import stale external document IDs.

Delete the isolated project only after recording the result:

```sh
docker compose down --volumes
```

Never run `down --volumes` against the production Compose project.

## Native Linux and external storage

Use the same quiesced boundary on native Linux: stop `navishai-jobs`, `navishai-web`, `navishai-runner`, and `navishai-supermemory`; dump all four PostgreSQL databases in custom format; archive the three paths under `/var/lib`; then restart services. Record binary/package versions and hashes of `/etc/navishai` files without placing secret values in the content archive.

For S3-compatible storage, use the provider's versioned snapshot or replication feature at the same stopped-writer boundary. Verify that every `active_storage_blobs.key` can be read in the restore test. A database-only backup is not complete.

The experimental Helm chart relies on platform snapshots for PostgreSQL, Rails storage, and runner state. Stop or scale down writers before those snapshots. Back up the customer-run Supermemory service under its own deployment contract. Do not claim a Helm backup as verified until it has passed the same isolated restore checks.

## Upgrade preflight

Build or pull the target images without changing the running services. Then run:

```sh
ops/compose/upgrade_preflight /secure/backups/navishai-2026-08-24
```

Preflight requires a verified backup, valid Compose configuration, a runner certificate valid for at least seven more days with the `runner` DNS SAN, PostgreSQL 15, and pgvector 0.8.1. It prints the target image's migration status against the current database so the operator can review the exact pending set. It does not migrate data or restart the application. Run it while the current Compose application is healthy; the target Rails check shares the live Supermemory network namespace.

After preflight, stop jobs and web, apply the target release, let web run `db:prepare`, then start jobs. Confirm `/up`, runner `/readyz`, queue processing, attachment download, and Memory health before ending the change window.

Database migrations set the rollback boundary. Before migration, roll back by restoring the old image set. After a migration starts, roll back only when every applied migration is documented as reversible and has passed an upgrade test. Otherwise restore the verified backup and old secret/config set. Never run old application code against a schema it has not been tested with. Never silently change PostgreSQL, pgvector, Supermemory, a runtime CLI, or its model during an application upgrade.
