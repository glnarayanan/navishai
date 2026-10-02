# Reset VPS recovery unit

`ops/vps/recovery.sh` is a runtime Bash library for the reset VPS CLI. It does not
call the proof-only `ops/database_recovery.rb`, `bin/prove-backup-restore` or
`bin/prove-upgrade`. Those scripts keep their separate schema and Rails evidence.

## Caller contract

Source the library from the root-only CLI after validating its owned installation.
Hold the same mutation lock for the whole operation, including upgrade rollback.
Obtain explicit destructive consent before restore. No command in this library
obtains consent, installs software, sends data off-host or starts app workloads.

The caller provides:

- `VPS_PREFIX=/opt/navishai-reset`, `VPS_CONFIG=/etc/navishai-reset` and
  `VPS_STATE=/var/lib/navishai-reset`, or the same paths under its managed test root.
- `VPS_PROJECT=navishai-reset`. `VPS_PREFIX/current` points to
  `releases/<40-character reviewed Git SHA>`; `VPS_RELEASE` names that verified,
  immutable directory. It contains `SOURCE_COMMIT`, the base `compose.yaml`, and
  `ops/vps/compose.yaml`. The library captures code identity, not a new Git review.
- `vps_compose`, scoped to that release, project and local Docker client;
  `vps_docker` uses the same client. Compose includes the validated optional
  `VPS_STATE/recovery-images.yaml` last.
- `vps_stop` stops web, jobs and proxy. `vps_load_env` reloads approved dotenv keys
  from `VPS_CONFIG/env` without executing its contents. `vps_start` belongs to the
  caller and must apply and verify IPv4/IPv6 policy before any app starts.

Both entry functions return nonzero on refusal or failure. **Both leave web, jobs
and proxy stopped, even on success.** Normal backup may call `vps_start` only after
success. Upgrade keeps writers stopped between backup, candidate migration and
rollback. Successful restore refreshes the caller's `VPS_RELEASE`, `VPS_IMAGE`
and safely loaded environment. PostgreSQL alone may run during recovery.

## Backup

Call `vps_backup /absolute/private/parent/new-backup-name`. The parent must exist;
the destination must not. Neither may sit inside the captured installation,
configuration or state tree. A previous backup is never overwritten.

After stopping and checking all three writer services, the unit captures one
stopped-writer recovery point:

- All four fixed databases: `navishai_lab_production` and its `_cache`, `_queue`
  and `_cable` databases. PostgreSQL 16 custom archives use `--create`, retain
  database/object owners, ACLs, default ACLs, sequence state and complete data.
- Only `navishai_setup` and `navishai` role hashes, login flags, inheritance and
  connection limits. Both must be restricted: no superuser, database/role
  creation, replication, RLS bypass, membership, expiry or role-setting override.
  Foreign owners or grantees in the four databases fail the backup.
- Exact release files and source SHA; each of postgres, web, jobs, proxy and
  app-net's configured image reference and actual container image ID. Docker
  retains the image content, not just tag names or registry availability.
- All files under private config and state, including secrets, install identity
  and bootstrap state. The active `install.lock` inode stays outside the archive.
- Rails storage and proxy certificate/config volumes. Names and Compose labels
  must match `navishai-reset_<fixed-volume-key>`, with
  `com.navishai.owner=navishai-reset`, driver `local` and no driver options.
  Every running or stopped volume user must be the exact scoped Compose container
  for its allowed service. Foreign users and copied labels fail closed.
- The standard PostgreSQL server files `postgresql.conf`, `postgresql.auto.conf`,
  `pg_hba.conf` and `pg_ident.conf` from `lab_postgres_data`. External include files
  and alternate configuration paths fail closed rather than disappear on restore.

The PG data volume's physical database files are not copied; logical archives
rebuild them. No cluster-wide role/global dump enters the backup.

The private staging directory sits beside the destination. Its complete fixed
artifact set has SHA-256 checksums; all files have mode 0600 and the directory has
mode 0700, owned by root. Validation and filesystem sync precede a same-filesystem,
no-replace rename. A failed capture removes its staging files and never publishes
a partial backup. Power loss or SIGKILL may leave exact private staging paths.

## Restore and rollback

Call `vps_restore /absolute/path/to/backup` only after consent and while holding
the lock. The unit stops writers even if validation later fails. It checks private
ownership/modes, links, artifact count, fixed checksum names, the manifest grammar,
both restricted roles, archive paths/types/owners/modes and database identity.
It copies the backup to private scratch space and checks the copy before use.

Tar files cannot contain absolute or parent paths, duplicate members, symbolic or
hard links, devices, set-id bits, control characters or unsupported file names.
Release/config/state/proxy files must use root ownership. Rails storage may also
use UID/GID 1000. The four PG config files must use UID/GID 999 and mode 0600.
Names use ASCII letters, digits and `_./@+:=-`; unsupported names fail, not change.
The library uses the pinned Debian PostgreSQL 16 UID/tool contract.

The pinned Caddy image uses mode 1777 for the root-owned `caddy/` directory in
both data/config volumes. Only those two archives accept that exact directory,
owner and mode. Every other member must stay root-owned with no group or other
write bits. Generic code/storage/image validators still reject this sticky
directory. Links, special nodes, set-id modes, writable children, foreign owners
and other sticky directories remain refused. Restore keeps Caddy's original mode;
it does not rewrite volume data to make a backup pass.

Restore loads retained images and checks their saved IDs. It writes a root-owned
0600 JSON Compose overlay containing only the five service image IDs. Docker
save/load does not preserve upstream RepoDigest aliases; this overlay permits
offline recovery without changing an immutable release or trusting a moved tag.
Upgrade removes the overlay after taking its backup and before candidate use.

After validation, restore takes the scoped composition down without deleting
volumes. Before that step, it checks all existing volume users and refuses client
sessions in any of the four app databases. A new client also makes `DROP DATABASE`
fail; restore never forces a client off the database. It selects the saved release,
restores config/state, keeps the lock inode, reloads dotenv safely,
replaces storage/certificate volume contents and starts
only PostgreSQL. An existing release under the saved SHA must match the archived
contents, ownership, modes and times; a collision fails rather than rewriting it.

The fixed local `navishai_admin` account supplies restore rights. Its bootstrap
attributes do not enter the role archive. Restore aligns its password with the
restored `POSTGRES_PASSWORD` using container environment and psql stdin, never
password arguments. It drops only the four fixed databases, restores each archive
with owners/ACLs intact, restores only the two fixed app roles, then stops
PostgreSQL to restore its saved server configuration. No downward migration runs.
Unrelated databases/roles remain outside the operation.

A failed or partial restore is not automatic success or permission to restart.
Keep writers stopped, inspect the named failure phase, repair the cause, and retry
the same retained backup. The source backup stays unchanged. The parent CLI owns
post-restore checks and gated startup, including upgrade health/rollback reporting.

## Checks and limits

```sh
bash -n ops/vps/recovery.sh test/support/vps_recovery_mock.sh
ruby test/ops/vps_recovery_test.rb
bin/rubocop test/ops/vps_recovery_test.rb test/support/vps_recovery_disposable.rb
# Explicit orb-only real Docker/PG check, not a production command:
ruby test/support/vps_recovery_disposable.rb
```

The unit tests use owned temporary root paths and command doubles. They require
root or passwordless sudo and never contact a Docker daemon or app database.
They test private publication, old-backup preservation, full file/volume rollback,
lock retention, caller refresh, strict input refusal and stopped partial recovery.

The separate disposable proof creates a supervised private Docker daemon with no
bridge, published port, host firewall rule or forwarding change. It downloads a
checksum-verified private Compose binary and the repository's pinned PostgreSQL
image; it installs no production tool or dependency. Its fixtures use real PG16
catalogs, restricted role logins, sequences and default grants, plus synthetic
code/writer/proxy stand-ins. Cleanup stops only its generated resources.

### Executed orb evidence, 2 October 2026

The Bash syntax check and focused RuboCop command above passed. The unit suite
initially passed with 10 tests, 30 assertions and no failures, errors or skips.
The real proof passed with Docker 29.8.1, Compose 2.39.4 and PostgreSQL 16.15:

- Foreign ACL/elevated-role backup refusal, and stopped shared-volume/live-client
  restore refusal without changing the database contents.
- Candidate additive schema, code, private config, three passwords and server
  setting rollback. All four data/sequence/owner/ACL/default-ACL catalogs matched.
  The lock inode, bootstrap state and unrelated role attributes remained intact.
- Recovery after deleting all four volumes, retained images and the saved release.
  Storage/certificate bytes and storage ownership matched. Password-based runtime
  logins, sequence value 48, future-object default grants and 20 privilege/trigger
  denials passed. Both successful operations kept writers stopped.

The proof reported `CLEAN`: it removed its exact daemon, containers, volumes,
images, archives and generated secrets. No orb service remained running.

The joined Rails/Caddy proof then found a real archive refusal: both actual Caddy
volumes contain root-owned `caddy/` mode 1777. A real-image metadata probe reproduced
both refusals under the generic root validator. The narrow Caddy archive rule above
has a red-to-green native regression for full backup/restore and unsafe near cases.
The updated unit suite has 11 tests / 33 assertions; the full operations suite
passes 57 / 540, with no failures/errors/skips. The corrected joined run remains
pending; the earlier standalone proof does not establish real Caddy recovery.

Relevant existing ops checks also passed:

```sh
ruby test/ops/edge_policy_test.rb
# 4 tests, 73 assertions; no failures/errors/skips.
sudo -n -u postgres env PATH="/home/user/.local/share/mise/installs/ruby/4.0.6/bin:/usr/lib/postgresql/16/bin:/usr/local/bin:/usr/bin:/bin" \
  /home/user/.local/share/mise/installs/ruby/4.0.6/bin/ruby test/ops/runtime_database_access_test.rb
# 7 tests, 42 assertions; no failures/errors/skips.
```

The latter uses this orb's PostgreSQL administrator and disposable names, not
production app privileges. Running it as the restricted default OS role failed
to create its test roles; sudo also needed the pinned Ruby directory in PATH.
No shared role gained rights. No Rails-wide or public-host check ran for this unit.
ShellCheck, Ponytail Audit and CE Code Review were not available; the unit received
Bash syntax checks, native Ruby lint, focused/real tests and a direct risk review.

These backups contain plaintext secrets, role hashes and retained company data.
Private modes and checksums are not encryption, signatures or permission to import
a backup from an untrusted root. Store copies under a separate approved encryption,
off-host retention and deletion policy. Checksums detect changed bytes, not a
malicious administrator who can rewrite both files and checksums. No PITR,
PostgreSQL major upgrade, arbitrary-scale timing, Rails boot, public HTTPS,
startup-policy acceptance, live-host recovery or customer-data proof follows from
this unit's synthetic tests. Files outside managed roots/volumes stay outside it.

Restore requires already validated installed roots and an env file. The disposable
proof tests recovery after deleting volumes, images and the saved release while
those roots remain. It does not supply a clean-host bootstrap CLI. Existing
unrelated databases/roles stay untouched during same-install rollback, but the
backup does not recover them after loss of the PG volume.
