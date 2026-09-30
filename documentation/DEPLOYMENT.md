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
