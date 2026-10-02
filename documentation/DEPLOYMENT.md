# Evaluation-lab hosting boundary

The current Compose composition contains web, Solid Queue jobs, and PostgreSQL 16.
It is a small baseline, not deployment acceptance. Old installers, Helm/native
topologies, runtime payloads, release scripts, archive tools and their proof have
been removed. Git history retains them. No release/deploy workflow was run.

Copy `.env.example` into a private environment file and supply app host, database
password, and SECRET_KEY_BASE. Compose uses a new project/volume and lab database
names: do not map an old helpdesk volume into it. Run database preparation once
before starting web/jobs; Rails maintains separate primary/cache/queue/cable
databases in production. The first-Owner bootstrap is protected by a deployment
token and expiry, not public registration. SMTP is required for production reset,
verification and invitation email; missing SMTP fails closed. Optional OIDC needs
issuer/client configuration and registered callback URLs.

Web binds only to the host loopback. Supply an HTTPS reverse proxy with trusted
forwarded headers; production enforces SSL and secure cookies. PostgreSQL is not
published on the host. Web/jobs drop capabilities and use no-new-privileges.
No runner, memory engine or arbitrary agent process exists. HTTP target execution
is off until the operator sets the private per-workspace endpoint registry in web
and jobs and an expert confirms disclosure. See [HTTP setup](./DEVELOPMENT.md#generic-http-target).
Network policy must deny private/special-use destinations even on the edge network;
the application also validates DNS and pins public addresses. No live endpoint is
configured or tested by default. Local deletion cannot recall remote copies.

Before claiming deployment readiness, independently verify a clean host, image
build, pinned PostgreSQL image digest, non-superuser database roles, HTTPS/proxy
configuration, mail/OIDC delivery, backup and restore, retention/deletion policy,
network boundaries and upgrades. Compose's PostgreSQL tag currently tracks 16;
this is a known reproducibility gap, not a certified release. Database owners and
superusers can bypass triggers; application roles must not be superusers or have
privileges to disable audit protections.

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
recorded-evaluation fixtures only into its source database, then creates a custom
format archive and restores it transactionally to the fresh destination. It never
dumps development, test, production or legacy data and changes no shared service.
Endpoint approval is empty; recorded/scripted evaluations run locally.

After restore it compares canonical SHA-256 fingerprints of every public table's
complete rows, checks recorded failure and corrected success on the same fixed
case, exact trace/approval provenance and held-out expert label/correction history.
Raw SQL must reject updates to 14 populated immutable definition/result/label
tables, run/item rebinding, foreign-workspace and same-workspace foreign-corpus
evidence inserts, and audit update/delete/truncate. A new audit append checks the
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
and superusers still can bypass triggers. Clean-host, Compose image build/digest,
HTTPS/proxy and production network/role acceptance remain unverified; this local
socket proof supplies none of those claims.
