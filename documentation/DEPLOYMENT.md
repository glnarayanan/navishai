# Evaluation-lab hosting boundary

The manual Compose composition contains web, Solid Queue jobs, and PostgreSQL 16.
The [reset VPS CLI](./VPS_CLI.md) adds a separate production override with Caddy,
gated IPv4/IPv6 startup, restricted preparation/runtime roles and full recovery.
Use that CLI for same-VPS fresh replacement, not the manual commands below.
Neither private test evidence nor a pinned image proves public-host acceptance.
Old installers, Helm/native
topologies, runtime payloads, release scripts, archive tools and their proof have
been removed. Git history retains them. No release/deploy workflow was run.

For the owner's disposable old CLI-managed install, use the separate
[preview-first uninstall tool](./LEGACY_UNINSTALL.md). It requires an exact
destruction plan, refuses shared resources and needs no mandatory backup.
It neither installs this reset nor converts an old database.

Copy `.env.example` into a private environment file and supply app host, distinct
runtime/preparation database passwords, and SECRET_KEY_BASE. Compose uses a new project/volume and lab database
names: do not map an old helpdesk volume into it. Run database preparation once
before starting web/jobs; Rails maintains separate primary/cache/queue/cable
databases in production. The first-Owner bootstrap is protected by a deployment
token and expiry, not public registration. SMTP is required for production reset,
verification and invitation email; missing SMTP fails closed. Optional OIDC needs
issuer/client configuration and registered callback URLs.

### Preparation and runtime roles

These commands describe only the manual baseline, not the reset VPS CLI.
No deployment ran in this work.
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
See [operations acceptance](./OPERATIONS_ACCEPTANCE.md) for namespace-only edge
controls and local upgrade/rollback evidence. Shared-host policy needs the owner's
approval; Compose alone does not enforce destination deny or safe startup ordering.

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
proof above. That trial had no tracked Compose proof script.

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

## Disposable Compose runtime proof

`bin/prove-compose-runtime` is a local orb operations test, not a deployment command
or part of `bin/ci`. It requires the installed Ruby, Git, Docker/dockerd, curl,
OpenSSL, namespace/mount tools and passwordless sudo, as the orb's UID-1000 user.
It accepts no arguments or shared daemon. It clears inherited application, provider,
Docker and Compose settings, archives the current tracked commit and prints that
commit plus its exact disposable project/directory names. Unstaged/private files
never enter the build. Inspect the tracked checkout before running it.

The script downloads official Compose v2.39.4 into its private directory and checks
the published SHA-256. It installs no global plugin or production dependency. A
supervised private build daemon uses separate vfs roots, no bridge, forwarding,
iptables, masquerading or publication. It pulls the existing pinned PostgreSQL
image and builds the tracked app with its existing dependencies. Images then move
to a second supervised daemon in an owned network namespace. Docker manages rules
only inside that namespace; the orb's routes, firewall, services and databases stay
unchanged. The namespace has no external default route.

Docker save/load does not preserve an upstream index RepoDigest reference. The
proof gives the unchanged pinned PostgreSQL image a disposable name and verifies
the same image ID after transfer. Only test image names and the unique project name
differ from the tracked composition. Control/edge topology, database initialization,
roles, capability settings, mounts and loopback publication remain unchanged.

The proof runs real preparation/grants for primary/cache/queue/cable before separate
web/jobs. Published namespace-loopback `/up` must return exactly HTTP 200. Actual
runtime checks require UID 1000, no effective capabilities, no-new-privileges, no
preparation credentials, empty disclosure registries, six SQL privilege denials,
cache write/read, cable access and audit rewrite rejection. Native jobs must finish
the synthetic two-family analysis. The shared test-only payload also serves the
separate socket/TLS proof; its security checks are not static Compose assertions.

PostgreSQL must have no publication or default route and must reach web over control.
Web must reach an edge-only generated/trusted TLS peer; PostgreSQL must receive
`ENETUNREACH`. That peer uses test-side curl, not an exception to application target
policy. It proves local reachability/isolation, not public egress, endpoint allowlist
enforcement, public TLS, clean-host acceptance, SMTP/OIDC or deployment readiness.

A separate controlled comparison held Docker 29.8.1, vfs, bridge/iptables/masquerade/
forwarding-disabled flags and the pinned Ruby HTTP helper constant. Disabling
userland proxy produced HTTP 000 after 5001 ms; enabling it produced HTTP 200 in
0.001339s. Direct-container requests returned HTTP 200 in both. This reproduces the
earlier publication symptom and establishes the flag's effect in that comparison;
it does not establish the removed daemon's exact failure cause. The full composition
uses userland proxy and namespace-local Docker rules and passes locally.

`PASS`/`CLEAN` cover only the executed checks. Cleanup attempts every exact created
service/project/container, volume, image, namespace mount, secret and archive.
Cleanup errors fail the command and print the exact remaining resources. Uncatchable
termination or host loss can still leave them; never clean by broad prefix matching.
No customer record, live endpoint, model, training or real credential enters this
test. The passing private socket/TLS proof remains separate evidence.

An independent rerun exposed caller `umask 077` stripping archive read/execute
permissions. The proof now owns its file mask while keeping the private directory
and secrets explicitly 0700/0600. The same restrictive-mask command passes all
checks and cleanup. On failure, bounded synthetic startup logs redact generated
secrets before cleanup; diagnostics do not turn a failed check into a pass.

## Disposable backup/restore fixture proof

Run `bin/prove-backup-restore` from the repository with the installed Ruby/bundle
and PostgreSQL tools (`psql`, `pg_dump`, `pg_restore`). It requires a local
PostgreSQL socket at `/var/run/postgresql` with peer authentication for the current
Unix user and permission to create/drop disposable databases and roles. This is an operations test,
not `bin/ci`, a deployment command or a production role recommendation.

The script accepts no database names or arguments, ignores inherited libpq
settings and overrides `DATABASE_URL`/Rails environment inside its own process.
It creates four unique `navishai_ops_<pid>_<random>` databases and two restricted
roles, loads the actual primary/cache/queue/cable schemas and synthetic fixtures,
and restores owner/ACL-preserving archives after deleting only those exact assets.
Real restored runtime logins test existing and future grants, lineage, immutable
receipts, tenant SQL guards, no resend, source expiry and purge. It never dumps
development, test, production or legacy data or calls a live endpoint.

The old primary-only/no-ACL proof is superseded. See
[operations acceptance](./OPERATIONS_ACCEPTANCE.md) for commands, exact evidence,
secret/backup lifecycle, cleanup and limits. This local proof does not establish
clean-host or production recovery acceptance, public ingress/egress/TLS, PITR,
backup encryption/retention, storage-volume recovery, RLS or customer quality.
