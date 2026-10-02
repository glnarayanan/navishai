# Evaluation-lab hosting boundary

The current Compose composition contains web, Solid Queue jobs, and PostgreSQL 16.
It is a small baseline, not deployment acceptance. Old installers, Helm/native
topologies, runtime payloads, release scripts, archive tools and their proof have
been removed. Git history retains them. No release/deploy workflow was run.

Copy `.env.example` into a private environment file and supply app host, distinct
runtime/preparation database passwords, and SECRET_KEY_BASE. Compose uses a new project/volume and lab database
names: do not map an old helpdesk volume into it. Run database preparation once
before starting web/jobs; Rails maintains separate primary/cache/queue/cable
databases in production. The first-Owner bootstrap is protected by a deployment
token and expiry, not public registration. SMTP is required for production reset,
verification and invitation email; missing SMTP fails closed. Optional OIDC needs
issuer/client configuration and registered callback URLs.

### Preparation and runtime roles

These commands describe an approved deployment; no deployment ran in this work.
Use a new volume. PostgreSQL's init script creates restricted `navishai`; the
bootstrap administrator is `navishai_setup`. `NAVISHAI_POSTGRES_PASSWORD` must
differ from `NAVISHAI_DATABASE_PASSWORD`. Only PostgreSQL and the one-off preparation
container receive the former. Supply it in the private shell environment through
your secret manager; a Compose `.env` file alone does not export shell variables.
Never print either value or put it in tracked files.

```sh
docker compose build
docker compose up -d postgres
NAVISHAI_PREPARE_PASSWORD="$NAVISHAI_POSTGRES_PASSWORD" docker compose run --rm --no-deps \
  -e NAVISHAI_PREPARE_PASSWORD web sh -ec '
    export NAVISHAI_DATABASE_USERNAME=navishai_setup
    export NAVISHAI_DATABASE_PASSWORD="$NAVISHAI_PREPARE_PASSWORD"
    unset NAVISHAI_PREPARE_PASSWORD
    exec bin/rails db:prepare db:grant_runtime
  '
docker compose up -d web jobs
```

Wait for PostgreSQL's health check before preparation. `db:grant_runtime` requires
production and a separate owner; it rejects elevated runtime-role flags. It grants
CONNECT, schema USAGE, table SELECT/INSERT/UPDATE/DELETE and sequence USAGE/SELECT
for primary/cache/queue/cable, including future owner-created tables/sequences.
It revokes public database access and schema creation. Runtime cannot create or
alter schemas, become the owner or disable triggers. Admins still can bypass them.
Web/jobs no longer prepare databases on startup, so concurrent starts cannot race
migrations. Starting before preparation fails; do not solve it by elevating runtime.
Upgrades require stopping web/jobs, approved owner-run preparation and grants, then
restart. This is not an automatic migration or old-volume conversion path.

Web binds only to the host loopback. Supply an HTTPS reverse proxy with trusted
forwarded headers; production enforces SSL and secure cookies. PostgreSQL is not
published on the host. Web/jobs drop capabilities and use no-new-privileges.
No runner, memory engine or arbitrary agent process exists. HTTP target execution
is off until the operator sets the private per-workspace endpoint registry in web
and jobs and an expert confirms disclosure. See [HTTP setup](./DEVELOPMENT.md#generic-http-target).
Network policy must deny private/special-use destinations even on the edge network;
the application also validates DNS and pins public addresses. No live endpoint is
configured or tested by default. Local deletion cannot recall remote copies.

Compose pins the public PostgreSQL 16 multi-platform index by digest. On 1 October
2026, the registry returned that digest for `postgres:16`; fetching the immutable
index produced the same SHA-256 and included Linux amd64/arm64 entries. This checks
manifest identity, not image execution or release security. Review and test a new
digest before changing it; do not leave security updates unreviewed indefinitely.

The Docker context excludes local Bundler config, all `config/**/*.key` files,
private environment files, runtime content and generated `public/assets`. Assets
compile inside the build. Only `log/.keep`, `storage/.keep` and `tmp/.keep` restore
their root runtime directories. A bare `!.keep` cannot match those nested paths;
Docker uses complete paths and parent prefixes, not recursive basename matching
([matcher source](https://github.com/moby/patternmatcher/blob/main/patternmatcher.go#L122-L163)).
This static rule review is not proof that an image contains no secrets. Build only
from a reviewed checkout and inspect the final image before deployment.

Native production checks passed in a disposable `git archive HEAD` checkout as
UID 1000, with an empty inherited environment, production-only frozen bundle,
`SECRET_KEY_BASE_DUMMY=1`, `NAVISHAI_APP_HOST=example.invalid` and an unused
database URL. `bin/rails assets:precompile` and `bin/rails zeitwerk:check` passed;
all 30 asset manifest entries resolved to files, including local CSS/fonts.
These commands did not create a database, start services or contact a provider.
They do not prove a Docker build, image permissions or clean-host acceptance.
Later isolated Docker builds and runtime checks passed; see the proof below.
Global Compose and Buildx plugins remain absent. A later partial Compose trial used
a private checksum-verified binary; see below. Neither is deployment acceptance.

Before claiming deployment readiness, independently verify a clean host, image
build, pinned image execution, non-superuser database roles, HTTPS/proxy
configuration, mail/OIDC delivery, backup and restore, retention/deletion policy,
network boundaries and upgrades. A pinned manifest is not a certified release.
Database owners and superusers can bypass triggers; application roles must not be
superusers or have privileges to disable audit protections.

## Disposable image/runtime proof

`bin/prove-container-runtime` is an orb-only operations check, not part of `bin/ci`
or a deployment command. It accepts no arguments and only uses the private local
Docker socket `tmp/navishai-image-proof/docker.sock`, not the global daemon.
Build the reviewed tree as `navishai-runtime-proof:local` first. The 1 October proof
used the installed legacy builder; it adds no Buildx/Compose plugin or app dependency.

The private daemon uses separate data/exec/pid roots, vfs, no bridge, iptables,
IP masquerading or userland proxy. Its supervised orb service publishes no port.
The proof supervises three uniquely named private containers, with network `none`,
all capabilities dropped and no-new-privileges. PostgreSQL uses the configured
immutable index, UID 999 and a fresh data directory. Rails uses UID 1000 and only
a shared password-authenticated Unix socket. Generated test secrets live in mode
0600 files in a private directory; they are not customer credentials.

The proof runs real `db:prepare db:grant_runtime` over all four databases, then
boots separate web/jobs without the preparation secret. Raw SQL must reject trigger
disablement, table/role/database creation and assuming the owner role. Synthetic
intake queues an analysis; the native jobs process must complete it. Cache
write/read, cable access and audit rewrite rejection must work under runtime grants.
A finite private TLS proxy verifies a generated trusted chain/hostname, production
sign-in, HSTS, CSP, secure cookies, compiled CSS with at least a year's public cache
and rejection of a foreign Host. It does not request a public certificate.

`PASS` and `CLEAN` record this executed proof. Normal completion or exceptions stop
only its named services and remove only its generated databases/secrets/directory.
Host loss can leave those exact disposable resources; inspect them before cleanup.
Existing lab/legacy databases and global Docker state remain untouched. The caller
stops the private daemon and removes its private build/cache directory after use.

This passed locally on 1 October 2026. It does not test Compose orchestration,
control/edge network egress policy, a clean external host, public TLS, SMTP/OIDC,
production backups/ACL restore, upgrades or customer quality. Earlier proof errors
came from service-name length, the upstream initializer clearing PGHOST, container
readiness timing and Rails using a 365.2425-day cache year; corrected the proof,
not the security controls. No live provider or customer data ran.

## Partial disposable Compose trial

An independent operations worker ran the tracked Compose composition from archived
[#166](https://github.com/glnarayanan/navishai/pull/166)
([`389162e`](https://github.com/glnarayanan/navishai/commit/389162e)), substituting only the built web/jobs image names. It made no
topology or security overrides. The worker downloaded official Compose v2.39.4
privately and verified its published checksum; it installed no production dependency.
This trial is separate from the passing `bin/prove-container-runtime` socket/TLS
proof above. There is no tracked Compose proof script.

The trial used the existing parent-owned `navishai-image-proof` daemon and exact
socket `tmp/navishai-image-proof/docker.sock`, with separate vfs data/exec/pid roots
and no bridge, iptables, masquerade or userland proxy. Preparation/runtime roles
worked across all four databases. Separate web/jobs completed a synthetic two-family
analysis; cache/cable access and audit denials passed.

PostgreSQL had no published port or default route and joined only the internal
control network. PostgreSQL-to-web control TCP passed; PostgreSQL-to-edge returned
`Network unreachable`. Web had an edge default route and `/up` returned HTTP 200
inside its container. Inspection showed host publication `127.0.0.1:3000:3000`, but
the host request timed out after 5001 ms with HTTP 000. The cause remains unverified;
the daemon flags are not a proved explanation. A TEST-NET probe cannot establish
useful public egress or allowlist enforcement.

The worker removed only its project, volumes, networks, generated secrets, private
CLI, archive and new image. Parent inspection found no containers and only the
host/none networks. No global daemon, firewall or network-policy changes occurred.
The private daemon stayed running after this trial for later scoped cleanup.

This is partial local trial evidence, not green Compose, egress or deployment
acceptance. Finish host ingress and useful-egress/deny-policy checks on a disposable
clean host with authority over proxy and network testing. No clean-host, public TLS
or production backup acceptance exists.

## Disposable backup/restore fixture proof

Run `bin/prove-backup-restore` from the repository with the installed Ruby/bundle
and PostgreSQL tools (`psql`, `pg_dump`, `pg_restore`). It requires a local
PostgreSQL socket at `/var/run/postgresql` with peer authentication for the current
Unix user and permission to create/drop databases. This is an operations test,
not `bin/ci`, a deployment command or a production role recommendation.

The script accepts no database names or arguments, ignores inherited libpq
settings and overrides `DATABASE_URL`/Rails environment inside its own process.
It creates two unique `navishai_lab_restore_<pid>_<random>` databases from
`template0`, loads the checked-in structure and synthetic authentication and
recorded-evaluation/batch-discovery fixtures only into its source database, then creates a custom
format archive and restores it transactionally to the fresh destination. It never
dumps development, test, production or legacy data and changes no shared service.
Recorded/scripted evaluations run locally. A source-reviewed two-turn conversation
and batch discovery use test-only approval and stubbed transport; neither sends a
request to a real endpoint. Both approvals return to empty before backup. All other
purpose registries stay empty.

After restore it compares canonical SHA-256 fingerprints of every public table's
complete rows, checks recorded failure and corrected success on the same fixed
case, exact trace/approval provenance and held-out expert label/correction history.
Trace association/correction history retains its exact trace, scenario version and
author without changing approval or labels.
It retains complete batch membership, fixed UUIDs and terminal receipts; duplicate
delivery after restore must not send. It also retains the approved conversation
plan, actual released transcript and fixed turn keys/receipts. Completed conversation
delivery after restore must not call the target again. Raw SQL rejects updates to 16
immutable definition/result/label tables, batch definition/terminal-state rewrites,
run/item rebinding, foreign-workspace and same-workspace foreign-corpus
evidence/association inserts, and audit update/delete/truncate. A new audit append checks the
restored sequence. Unexpected SQL errors fail rather than masquerade as protection.

Success prints `PASS` and `CLEAN`; failure exits nonzero. The private temporary
directory/archive and only successfully created database names are cleaned on
normal completion or Ruby exception. Uncatchable termination (such as SIGKILL or
host loss) can leave disposable resources; inspect that invocation's exact names
before manual removal, never drop databases using a broad prefix wildcard.

Local orb execution on 1 October 2026 passed this fixture proof. This covers the
primary lab schema, not separate production queue/cache/cable databases, backup
encryption/retention, PITR, role/ACL restoration (owner and ACL data are omitted),
RLS, all possible composite relationships, live targets or model quality. Owners
and superusers still can bypass triggers. Clean-host, end-to-end Compose ingress/
egress, public HTTPS/proxy and production network/role acceptance remain unverified;
this local socket proof supplies none of those claims.
