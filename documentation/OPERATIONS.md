# Backup, restore, and upgrades

PostgreSQL is authoritative for tenant, business, audit, policy, memory, and execution-ledger data. A complete backup also needs uploaded file bytes, runner admission state, Supermemory state, deployment configuration references, and the secret store managed outside NavishAI.

Do not copy a live local file or Supermemory store. Stop every writer before taking those archives. Keep backup encryption, access control, expiry, and off-site copies in the operator's backup system. NavishAI archives contain customer content even when the files have opaque names.

## Provider connections

The deployment owner supplies approved adapter binaries, runner-readable subscription credential homes, deny-by-default egress profiles, and immutable execution-policy ceilings. NavishAI does not install a provider CLI, open a provider browser or terminal, or create a subscription login. After that bootstrap, a Workspace Owner or Admin uses **Providers** to connect an API key or select an existing runner login, choose the supported model, test the exact configuration, and approve access. Configure and remove apply immediately; they do not require an edit to `/etc/navishai/execution.json` or a runner restart.

An API key crosses Rails only in the synchronous signed configure request and is stored only in the encrypted Workspace-scoped vault at `<NAVISHAI_RUNNER_STATE_PATH>.providers`. Preserve that file with runner state and preserve `NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET` separately in the host secret manager. Losing or changing the vault secret makes the saved provider state unreadable. A provider connection change alters its configuration fingerprint and invalidates stale test and approval evidence; run admission also checks the exact frozen fingerprint and effective model. Workspace deletion first purges that Workspace's provider connections and request history from the vault. If the provider service cannot confirm the purge, deletion fails visibly and remains available for an Owner retry instead of leaving unreachable credentials behind.

## Reliability cockpit

Managers, Admins, and Owners use **Reliability** to read one bounded view of connector intake, Workspace-scoped runner admission and failure, unknown customer sends, Memory indexing, retention, archives, backup and restore checks, and upgrade preflight. Each section shows `healthy`, `attention`, `blocked`, `unknown`, or `not configured`. Missing or stale evidence never appears as healthy. Shared Solid Queue rows and process heartbeats are not Workspace evidence and are excluded from this view. This view aids diagnosis; it does not replace host alerts or an external monitor.

The cockpit can reconcile one saved runner admission, start an idempotent retry after a definite retryable run failure, and rebuild missing, failed, unknown, or stale Memory index work from PostgreSQL. Each action rechecks the signed-in role and asks for confirmation. An unknown customer send offers only a link to the exact Case. Check the external channel before any new human send; never retry from the cockpit.

Host checks for archive verification, backup verification, restore rehearsal, and upgrade preflight may record only a result, bounded result code, SHA-256 evidence digest, source commit, check time, optional archive format and counts, and an exact human actor when one exists. These rows are append-only. Do not put logs, archive content, paths, credentials, or secret values in them. A passing check becomes `attention` after 30 days; a missing check remains `not configured`.

## Verified Workspace archive round trip

Set `NAVISHAI_SOURCE_COMMIT` to the exact 40-character Git commit deployed with Rails. Compose, the native systemd environment, and the Helm chart pass this value to the application. The check stays disabled when the value is missing or invalid.

An Owner selects **Data**, reviews **Archive round-trip check**, and confirms **Run archive round-trip check**. The check uses the current Workspace archive format. It exports the selected Workspace and imports it into a new empty Workspace in the same Organisation. Manual export and import remain separate actions with the same archive contract.

Before it passes, the check proves:

- the count and normalized SHA-256 digest of every authoritative Workspace table;
- fresh global keys, exact critical ID remaps, audit actor attribution, and target-only tenant links;
- attachment count, total bytes, and each object's SHA-256 digest;
- one durable indexing claim and job for every current available Memory record rebuilt from PostgreSQL, with no engine-private document ID, status, or indexed time.

A pass retains the target Workspace so the Owner can inspect it. The success notice names that target. Delete it through the normal protected Workspace deletion flow only after review. Target creation and the passing operational record commit together. A partial import, table count or digest drift, attachment mismatch, unsupported schema, missing verified user, cross-Organisation archive, tenant-link failure, uncertain Memory reconstruction, or success-ledger failure rolls back the target and removes newly uploaded target objects. Source objects remain unchanged.

The source Workspace receives one append-only `archive_verification` operational check. It contains only the source commit, current archive format, checked time, counts, passed or failed result, bounded result code, and one SHA-256 evidence digest. It keeps no archive content, object path, log, engine ID, credential, or secret. The **Reliability** cockpit shows the latest result.

## Intercom historical backfill

An Owner or Admin opens **Intercom** and starts a dry run for one active connection. The dry run uses only Intercom GET requests. It writes no customer record, tag, assignment, note, or reply. NavishAI retains a bounded manifest with the exact discovery digest, date range, counts, identity results, and expected exceptions for 30 minutes.

Review the manifest, then confirm that exact digest. Confirmation repeats discovery and rejects an expired, changed, used, missing, or cross-Workspace manifest before customer writes. The job imports at most 25 conversations per batch. Each conversation, part, attachment link, and cursor update commits as one local outcome. An interrupted record rolls back and stops at the prior definite cursor. An enqueue failure leaves the run failed with `enqueue_error`; choose **Resume from definite record** after queue service returns.

NavishAI never guesses an ambiguous identity. Choose one candidate in the existing identity review, then resume from the same record. Inspect unsupported fields and rejected or quarantined attachments through their listed recovery action. Attachment downloads enforce public HTTPS, DNS and redirect checks, a 5 MiB file limit, type and SHA-256 checks, malware scan state, and the normal download authorisation. A failed local transaction deletes its newly uploaded object before retry.

The complete state shows discovered, imported, matched, skipped, ambiguous, unsupported, failed, and pending counts plus the full report digest. Do not call the run complete while any count remains failed or pending. The backfill has no remote-write recovery command. Use normal Intercom reconciliation for later source changes.

The M6 deterministic proof links one GET-only imported conversation to its exact discovered, imported, matched, pending, failed, and unsupported counts and report digest. A verified Workspace archive round trip retains that row and report, then rebuilds its available Memory record from PostgreSQL without an engine-private document ID. This source proof does not replace a deployment-owned backup, restore rehearsal, credential smoke test, or external Intercom check.

## Governed policy change

An Owner or Admin opens **Policies** and proposes one immutable resolution contract and crew-profile policy version. Choose only named current cases, named Accounts, or the one bounded crew profile. NavishAI has no percentage rollout or implicit broad scope. Managers, Members, and Viewers cannot propose, preview, publish, or roll back policy.

Preview reads retained Workspace facts, artifacts, evidence, runtime capability and approval state, and usage. It does not run a model, call the runner, search the public web, write to an integration, or send or schedule a customer message. It shows the current and proposed grounding, quality-review, routing, fallback, and budget decisions with the exact typed facts and stable SHA-256 digests. It cannot predict response quality, customer behavior, resolution rate, or a causal outcome.

Publish only the preview shown for that exact proposal and scope. Publication fails if the preview is missing, expired, changed, stale against current policy, role, runtime, scope, or retained records, or no longer meets the human-authority security check. Work outside the named Workspace scope keeps the current published contract and profile. Affected new tasks, handoffs, runs, artifacts, and reviews show and retain the exact canary or rollback selection.

Rollback requires a bounded reason and the exact current publication. It selects the proposal's prior versions for future work in the same named scope. It never changes completed tasks, task events, runs, artifacts, reviews, decisions, actors, digests, or outcomes. Retention may redact policy reasons and preview payloads while keeping immutable IDs, actors, version links, audit history, and original digests. Workspace archives remap governed links and recompute imported preview digests; protected Workspace deletion removes governed rows with the rest of that Workspace.

## Compose backup

Run from the checked-out release root:

```sh
ops/compose/backup /secure/backups/navishai-2026-08-24
ops/compose/verify_backup /secure/backups/navishai-2026-08-24
```

The backup command starts PostgreSQL if needed, stops jobs, web, and the runner, dumps all four databases, then stops Supermemory while copying its state. It restarts the application after the snapshot. If any step fails, it tries to restart the application and leaves the partial directory for diagnosis; never treat that directory as a backup.

The `navishai-backup-v1` directory contains:

- custom-format dumps for primary, cache, queue, and cable PostgreSQL databases;
- tar archives for Rails local storage, runner state including the encrypted provider vault, and Supermemory state;
- the exact container image references;
- the source Git revision and SHA-256 digests for `compose.yaml` and `.env`;
- environment key names, but no environment values;
- SHA-256 checksums for every archive member.

Back up `.env`, the provider-vault secret, runner TLS keys, SMTP and integration secrets, runtime subscription credential homes, and any external object-store credentials in the host's secret manager. The archive records the `.env` digest so an operator can match the separately protected copy without exposing it. A restore must pair the provider vault with the same vault secret; do not treat an unreadable or newly empty vault as a successful restore.

`verify_backup` checks every checksum, uses the PostgreSQL image pinned by the current Compose configuration to parse each database dump, and reads every tar directory. It never runs an image reference supplied by the archive. It does not need a running database, but Docker may need to pull the configured image. Verification does not prove restore. Run a restore test on a schedule and before an upgrade.

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

Preflight requires a verified backup, valid Compose configuration, a runner certificate valid for at least seven more days with the `runner` DNS SAN, PostgreSQL 15, and either the previously supported pgvector 0.8.1 extension or pgvector 0.8.6. It also proves that the target PostgreSQL image makes pgvector 0.8.6 available. It prints the target image's migration status against the current database so the operator can review the exact pending set. It does not migrate data or restart the application. Run it while the current Compose application is healthy; the target Rails check shares the live Supermemory network namespace.

After preflight, stop jobs and web, apply the target release, let web run `db:prepare`, then start jobs. Confirm `/up`, runner `/readyz`, queue processing, attachment download, and Memory health before ending the change window.

Database migrations set the rollback boundary. The pgvector 0.8.6 migration is intentionally irreversible because PostgreSQL extensions do not provide a supported downgrade path. Before migration, roll back by restoring the old image set. After that migration starts, restore the verified backup and old image, secret, and config set to roll back. Never run old application code against a schema or extension version it has not been tested with. Never silently change PostgreSQL, pgvector, Supermemory, a runtime CLI, or its model during an application upgrade.
