# PostgreSQL 18 upgrade

The lab moves from PostgreSQL 16 to 18. PostgreSQL 16 is supported until November
2028; 18 is supported until November 2030. Rails 8.1 and the `pg` gem support 18.

## What changes

- **Image.** Compose pins `postgres:18` by its multi-platform index digest
  `sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6`
  (PostgreSQL 18.6). On 22 October 2026 the registry returned that digest for both
  `postgres:18` and `postgres:18.6`; the index lists linux amd64, arm64, arm/v5,
  arm/v7, 386, ppc64le, riscv64 and s390x.
- **Volume.** The 18 image keeps its cluster in `/var/lib/postgresql/18/docker` and
  refuses to start on a mount at `/var/lib/postgresql/data`. Compose now mounts a
  new volume, `lab_postgres18_data`, at `/var/lib/postgresql`. The 16 volume,
  `lab_postgres_data`, is no longer declared, mounted or created. It is never
  deleted by this change.
- **Data.** PostgreSQL 18 cannot open a 16 data directory. Data moves by logical
  dump and restore, not `pg_upgrade`.
- **App image.** Debian trixie ships client 17, whose `pg_dump` refuses an 18
  server. The `Dockerfile` installs `postgresql-client-18` (and the matching
  `libpq5`) from the PostgreSQL apt repository, using the signing key shipped in
  Debian's `postgresql-common` package. The VPS backup itself already runs
  `pg_dump`/`pg_restore` inside the database container.
- **Recovery.** `ops/vps/recovery.sh` accepts exactly two layouts: 16 at the root of
  `lab_postgres_data` (so pre-migration backups still restore) and 18 in
  `18/docker` inside `lab_postgres18_data`. Its server-file checks follow the
  running layout. See [VPS recovery](./VPS_RECOVERY.md#postgresql-18-migration).

## Reset VPS: maintenance runbook

Plan a short window: web, jobs and the proxy are down from the backup until the
new release passes its start gates. The migration needs free disk for one more
backup and a second database cluster, roughly twice the database size.

### Why the installed command is not enough

`sudo navishai upgrade` runs the installed (16-era) CLI. That code cannot move the
data. It still fails safe: the new release's start gate sees the 16 volume without
a completed migration, refuses before any schema is prepared, and the old CLI
restores its backup and stays stopped. Use the new release's own CLI once, from a
checkout, as below. Later upgrades use `sudo navishai upgrade` again.

### Steps

1. **Check the host.** Confirm the reviewed SHA of the merged PostgreSQL 18 release
   and enough disk:

   ```sh
   sudo navishai status
   sudo docker system df -v | grep -E 'VOLUME NAME|lab_postgres'
   df -h /var/lib/docker /root
   ```

2. **Check out the reviewed release** (a fresh directory; `/root/navishai-source`
   stays as it is):

   ```sh
   SHA=<full 40-character SHA of the PostgreSQL 18 release>
   sudo git clone --quiet --no-checkout https://github.com/glnarayanan/navishai.git /root/navishai-pg18
   sudo git -C /root/navishai-pg18 checkout --quiet --detach "$SHA"
   ```

3. **Run the upgrade with the new CLI:**

   ```sh
   BACKUP=/root/navishai-backups/$(date -u +%Y%m%d-%H%M%S)-pre-postgres18
   sudo /root/navishai-pg18/bin/navishai-vps upgrade \
     --source /root/navishai-pg18 --commit "$SHA" --backup "$BACKUP"
   ```

   That one command performs the maintenance steps in order, and stops at the
   first failure:

   | Step | What runs |
   | --- | --- |
   | Stop web and jobs | `vps_backup` stops web, jobs and the proxy, and refuses while any client is connected to the four app databases. |
   | Back up with `ops/vps/recovery.sh` | The installed release's `vps_backup` writes the full recovery point to `$BACKUP` on PostgreSQL 16. |
   | Keep the old volume untouched | The new release's Compose files do not mention `lab_postgres_data`; nothing mounts it again. |
   | Start 18 on a new volume | PostgreSQL 18 initialises `lab_postgres18_data` and runs `ops/vps/initialize_roles.sh`. |
   | Restore | `vps_recovery_migrate "$BACKUP"` checks the backup again, lists each dump with the 18 `pg_restore`, then restores the four databases, the two app roles and the four server files. |
   | Verify role and config parity | Database owners and dependencies (`vps_recovery_database_check`), the role dump equal to `roles.tsv` byte for byte, the four server files equal to `postgres-config.tar` byte for byte with no parse errors or include files. Only then is `/var/lib/navishai-reset/postgres18-migrated` written. |
   | Start web and jobs | The usual gates: network policy, `db:prepare`/`db:grant_runtime`, `zeitwerk:check`, pending-migration and runtime-role checks, web readiness, proxy, verified local HTTPS. Then `check` and `status`. |

4. **Verify.**

   ```sh
   sudo navishai status
   pg=$(sudo docker ps -q --filter label=com.docker.compose.project=navishai-reset --filter label=com.docker.compose.service=postgres)
   sudo docker exec "$pg" psql -X -U navishai_admin -d postgres -Atc 'SHOW server_version'   # 18.6 ...
   sudo docker volume ls --filter label=com.docker.compose.project=navishai-reset         # both volumes listed
   sudo cat /var/lib/navishai-reset/postgres18-migrated; sudo sha256sum "$BACKUP/CHECKSUMS"  # same hash
   ```

   Sign in and open a workspace with recent evaluations. If you compare table
   ACLs with 16, owners now show `arwdDxtm` instead of `arwdDxt`: PostgreSQL 17
   added the `MAINTAIN` privilege to an owner's implicit rights. Explicit grants,
   such as the runtime role's `arwd`, are unchanged.

5. **Take a fresh backup on 18** once satisfied. It restarts the app afterwards.

   ```sh
   sudo navishai backup --output /root/navishai-backups/$(date -u +%Y%m%d-%H%M%S)-postgres18
   ```

6. **Keep the fallback.** Keep `$BACKUP` and the `navishai-reset_lab_postgres_data`
   volume until you no longer want to roll back (suggested: at least two weeks).
   Removing the volume is a separate, deliberate step:
   `sudo docker volume rm navishai-reset_lab_postgres_data`.

### Rollback

Rollback is the 16 image plus the untouched 16 volume, using the pre-migration
backup:

```sh
sudo navishai stop
sudo sha256sum "$BACKUP/CHECKSUMS"
sudo navishai restore --from "$BACKUP" --confirm-restore <that SHA-256>
sudo navishai start
```

Restore brings back the 16 release, its saved images, config, state, Rails storage
and certificates. Because the migration marker names this exact backup, restore
starts PostgreSQL 16 on `lab_postgres_data` and only verifies it: database owners,
roles and server files must match the backup, and no database is dropped or
rewritten. Anything written while on 18 is not carried back. The 18 volume stays
for inspection. A later retry of the upgrade restores a fresh backup into it again.

If the upgrade command itself fails, it rolls back the same way on its own and
leaves writers stopped. Read the error, then `sudo navishai start` the old release
or retry the upgrade. Restoring a backup that the marker does not name (or after
the 16 volume was removed) falls back to the normal full restore.

## Plain Compose installs with existing data

Plain `docker compose up` has no migration gate. Deploying the 18 release over a
16 install starts an empty cluster on the new volume, and `prepare` builds an
empty schema; the data stays in the old volume. Pause any auto-deploy (for
example Dokploy) first, then, from the directory holding `compose.yaml` and its
`.env`:

```sh
# On the current 16 release:
docker compose stop web jobs
for db in navishai_lab_production navishai_lab_production_cache navishai_lab_production_queue navishai_lab_production_cable; do
  docker compose exec -T postgres pg_dump -U navishai_setup -d "$db" --format=custom --create > "$db.dump"
done
# Switch the checkout to the 18 release, then start only PostgreSQL 18:
docker compose up -d --wait postgres
for db in navishai_lab_production navishai_lab_production_cache navishai_lab_production_queue navishai_lab_production_cable; do
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U navishai_setup -d postgres -c "DROP DATABASE IF EXISTS $db"
  docker compose exec -T postgres pg_restore -U navishai_setup -d postgres --create --exit-on-error < "$db.dump"
done
docker compose up -d --build
```

The runtime role `navishai` is recreated from `NAVISHAI_DATABASE_PASSWORD` by the
init script, and `prepare` re-applies its grants. The dumps hold application
data: keep them private and delete them when done. Rollback is the previous
checkout; its Compose file still names the untouched `lab_postgres_data` volume.

## Evidence

The rehearsal and test results for this change are in its pull request. The
real-Docker proof `test/support/vps_recovery_disposable.rb` now runs the VPS path
end to end: backup on 16, migrate into a fresh 18 cluster, compare all four
database catalogs, log in with all three passwords, back up and restore on 18,
then roll back to 16 and confirm the same database OIDs.
