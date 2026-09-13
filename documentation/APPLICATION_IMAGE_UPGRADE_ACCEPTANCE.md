# Application-image upgrade acceptance

This procedure proves a **changed application image** on a disposable Docker-capable host. It does not prove PostgreSQL major upgrades, Supermemory upgrades, provider CLI upgrades, schema-changing migrations, public ACME, or a general installer audit.

Fixture coverage lives in `test/scripts/installer_test.rb`. Live digest proof is **BLK-002** until this procedure is executed on a host with Docker Engine and Compose v2.

## Supported candidate

The target is supported only when all of the following hold, checked **before** writers stop:

- Compose service names match the installed release.
- Infrastructure image references are unchanged (`postgres`, `runner`, `app-net`, `supermemory`, `caddy`, and any other non-`web`/`jobs` service).
- `web` and `jobs` share one application image.
- PostgreSQL remains digest-pinned pgvector at the installed major (15 or 16).
- Both `images.tar` archives are Docker save manifests. Runner and Supermemory tags and config digests match. At least one `navishai-rails:*` config digest differs.
- `bin/rails db:migrate:status` against the live database reports no `down` migrations.

Opaque or unreadable image archives, runner/memory image changes, topology changes, pending migrations, and PostgreSQL major mismatches remain rejected. The previous identical-archive upgrade path is unchanged.

## Live host procedure

Use an isolated Compose project and a verified backup. Do not run this against a customer install.

1. Record the installed release id, `SOURCE_COMMIT`, and `docker image inspect --format '{{.Id}}' navishai-rails:local` (or the running `web` image id).
2. Build a target candidate whose Rails image id differs and whose runner and Supermemory image ids match. Keep `db/structure.sql` identical to the installed schema so migrate status has no `down` rows.
3. `navishai backup` then `navishai upgrade VERIFIED_BACKUP TARGET.tar --confirm-apply`.
4. Confirm writers were not stopped until after the target image loaded and migrate status passed.
5. Confirm `navishai status` shows the target `SOURCE_COMMIT`, HTTPS `/up` returns 200, and a visible release identity in the running web container matches the new image id.
6. Confirm authoritative rows, one uploaded attachment digest, and runner-vault readability metadata are unchanged.
7. Repeat with an injected web healthcheck failure before promotion completes. Expect the previous application image and `SOURCE_COMMIT` restored, or a clear unrecoverable restore requirement. Do not treat a second promotion of the same failed candidate as success.
8. Interrupt after promotion (kill the upgrade process once `upgrade_app_image_promoted` is recorded). Rerun the same upgrade. Expect resume to finish or refuse without a second promotion of a rolled-back candidate.
9. Repeat with a runner or Supermemory image change, a pending migration, and a Compose topology change. Expect rejection **before** `compose stop`.

Record the host OS, Docker versions, old/new Rails image ids, operator commit, backup id, and exact command output in [INSTALLER_ACCEPTANCE_EVIDENCE.md](./INSTALLER_ACCEPTANCE_EVIDENCE.md). Do not claim schema-change compatibility or production deployment from this procedure.
