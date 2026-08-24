# Deployment

NavishAI supports Docker Compose and native Linux. The Helm chart is experimental. All modes run Rails web, Rails jobs, the runner, PostgreSQL, and self-hosted Supermemory as separate processes. The runner never receives a Docker socket.

Put TLS in front of the Rails web process. Keep PostgreSQL, the runner, and Supermemory on private networks. Rails accepts cleartext runner traffic only on loopback. It verifies a remote runner with the operating system roots plus the private CA set by `NAVISHAI_RUNNER_CA_FILE`.

## Docker Compose

Requirements:

- Docker Engine with Compose v2
- an HTTPS reverse proxy for the public host
- enough persistent storage for PostgreSQL, uploaded files, runner admission state, and Supermemory

Set up and start the stack:

```sh
cp .env.example .env
bin/rails secret
script/generate_runner_tls
# Put the generated secret and all other required values in .env.
docker compose build
docker compose up -d
```

Compose binds Rails to port 3000 by default. Set `NAVISHAI_HTTP_PORT` to change the host port. Rails, jobs, and Supermemory share one container network namespace so Rails can use Supermemory's supported loopback HTTP endpoint. They remain separate processes and images. The runner has its own container and receives no Docker socket. The control network is internal. Put the reverse proxy on the edge side and send the original HTTPS host.

Supermemory needs its first-boot local model setup. Start it, complete that setup according to its local prompt, then place its generated key in `NAVISHAI_SUPERMEMORY_API_KEY` and recreate `web` and `jobs`. A placeholder value may be used for the first Supermemory boot. The Lite build has a 10,000-document licence cap.

Keep `.env` and `ops/secrets/runner` outside source control. Back up both through the host's secret and backup systems. To rotate runner TLS, stop `web`, `jobs`, and `runner`, remove the three generated runner TLS files, run `script/generate_runner_tls`, then restart those services. Rotating the shared secret also requires one coordinated stop and restart.

To enable OpenID Connect, set the three optional `NAVISHAI_OIDC_*` values in `.env`. Keep the client secret in the host secret store. Leave all three blank to keep single sign-on off.

Optional S3-compatible object storage and SearXNG remain external. Configure them only when used; the default stack has no general runner egress.

## Native Linux

The supported layout is:

- `/opt/navishai/current`: an immutable release tree with bundled gems and compiled assets
- `/etc/navishai`: root-owned environment and runner TLS files, mode `0750` for the directory and `0640` or tighter for files
- `/var/lib/navishai`: Rails `log`, `storage`, and `tmp` directories, owned by `navishai` and linked from the matching paths in the release tree
- `/var/lib/navishai-runner`: runner state and run roots, owned by the separate `navishai-runner` user
- `/var/lib/supermemory`: Supermemory state, owned by `supermemory`
- a PostgreSQL 15 server with pgvector 0.8.1 and four databases named in `config/database.yml`

Build the three Go binaries from the pinned Go toolchain and install them in `/usr/local/bin`. Install the pinned Supermemory binary with `script/install_supermemory`, then copy it to `/usr/local/bin`. Bundle Rails with the locked gems and precompile assets with `SECRET_KEY_BASE_DUMMY=1`.

Copy the units and environment examples from `ops/systemd` into the host's systemd and `/etc/navishai` directories. Replace every `change-me` value. Issue the runner certificate with SAN `127.0.0.1` when using the example loopback URL, or use a DNS SAN that matches `NAVISHAI_RUNNER_ADDRESS`. Link the release's `log`, `storage`, and `tmp` paths to their matching writable directories under `/var/lib/navishai`. Block inbound access to ports 6767 and 8081 in the host firewall; only local services should reach them. Then run:

```sh
systemctl daemon-reload
systemctl enable --now navishai-runner navishai-supermemory navishai-web navishai-jobs
```

The web unit runs `db:prepare` before boot. Do not run migrations from the jobs or runner users. Check `GET /up` through the reverse proxy and the runner's `GET /readyz` endpoint after each restart.

## Experimental Helm

The chart at `ops/helm/navishai` is cloud-neutral and does not install PostgreSQL, Supermemory, an ingress controller, or a certificate manager. Supply PostgreSQL 15 with pgvector 0.8.1, an ingress, storage classes, and immutable image references through your platform. Supply a customer-run Supermemory Local endpoint behind HTTPS with a certificate trusted by the Rails image; its stock binary has no TLS listener, so the platform must terminate TLS next to it.

Create the application secret with these keys:

- `SECRET_KEY_BASE`
- `NAVISHAI_DATABASE_PASSWORD`
- `NAVISHAI_RUNNER_SHARED_SECRET`
- `NAVISHAI_SUPERMEMORY_API_KEY`

To enable OpenID Connect, also add `NAVISHAI_OIDC_ISSUER`, `NAVISHAI_OIDC_CLIENT_ID`, and `NAVISHAI_OIDC_CLIENT_SECRET` to this Secret. Omit all three to keep it off.

Create the runner TLS secret with `tls.crt`, `tls.key`, and `ca.crt`. The certificate DNS SAN must match `<release>-navishai-runner` in the target namespace. Set the database host, app host, image tags or digests, storage classes, replica counts, and resource limits in a private values file. Validate before install:

```sh
helm lint ops/helm/navishai -f production-values.yaml
helm template navishai ops/helm/navishai -f production-values.yaml >/dev/null
```

The chart keeps runner state on one persistent StatefulSet replica. Do not increase runner replicas until its state has moved to a shared, concurrency-safe service. Rails storage defaults to `ReadWriteMany`; use object storage instead when the platform cannot provide it.

## Boundaries

Deployment files do not set SMTP, Intercom, runtime subscription, or object-storage credentials. Supply only the integrations in use. Never place runtime subscription credentials in Rails; they belong on the runner and must stay scoped to approved adapters.

Use [OPERATIONS.md](./OPERATIONS.md) for backup, restore tests, and upgrade preflight. Use [RELEASE.md](./RELEASE.md) for release artifacts, checksums, signatures, and the SBOM.
