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
mkdir -p ops/runtime-executables ops/runtime-state
# Put the generated secret and all other required values in .env.
docker compose build
docker compose up -d
```

Compose binds Rails to port 3000 by default. Set `NAVISHAI_HTTP_PORT` to change the host port. Rails, jobs, and Supermemory share one container network namespace so Rails can use Supermemory's supported loopback HTTP endpoint. They remain separate processes and images. The runner has its own container and receives no Docker socket. The non-root application containers drop Linux capabilities and cannot gain new privileges. The control network is internal. Put the reverse proxy on the edge side and send the original HTTPS host. Rails rejects every Host other than `NAVISHAI_APP_HOST`; only `/up` skips that check for local health probes.

Supermemory needs its first-boot local model setup. Start it, complete that setup according to its local prompt, then place its generated key in `NAVISHAI_SUPERMEMORY_API_KEY` and recreate `web` and `jobs`. A placeholder value may be used for the first Supermemory boot. The Lite build has a 10,000-document licence cap.

Keep `.env` and `ops/secrets/runner` outside source control. Back up both through the host's secret and backup systems. To rotate runner TLS, stop `web`, `jobs`, and `runner`, remove the three generated runner TLS files, run `script/generate_runner_tls`, then restart those services. Rotating the shared secret also requires one coordinated stop and restart.

To enable OpenID Connect, set the three optional `NAVISHAI_OIDC_*` values in `.env`. Keep the client secret in the host secret store. Leave all three blank to keep single sign-on off.

Optional S3-compatible object storage and SearXNG remain external. Configure them only when used; the default stack has no general runner egress.

The checked-in runner execution policy starts with all live adapters disabled. `NAVISHAI_RUNNER_EXECUTION_CONFIG_PATH` selects the deployment-owned infrastructure template, `NAVISHAI_RUNTIME_EXECUTABLES_PATH` mounts approved CLI files at `/opt/navishai/runtimes`, and `NAVISHAI_RUNTIME_STATE_PATH` mounts pre-existing subscription credential homes at `/var/lib/navishai/runtime`. Keep those host directories and credential files out of source control and make the homes readable by the container's runner UID; the example mounts them read-only because subscription login is completed on the host, outside NavishAI. A live adapter also needs an exact executable approval and a deployment-owned subordinate user/network namespace egress profile in the immutable policy ceiling. Compose does not create those host security boundaries. Leave the adapter disabled until the namespace files, firewall or allowlisting proxy, TLS roots, executable, and any subscription login are present. The runner sends signed events back to Rails over the private, internal Compose network; the explicit cleartext opt-in applies only to that link. Its admission state, pending event outbox, runtime-test state, and encrypted provider vault are writable and persistent on `runner_data`. Workspace Owners and Admins then connect API-key or existing-login providers in **Providers** without editing the policy or restarting the runner.

## Native Linux

The supported layout is:

- `/opt/navishai/current`: an immutable release tree with bundled gems and compiled assets
- `/etc/navishai`: root-owned environment and runner TLS files, mode `0750` for the directory and `0640` or tighter for files
- `/var/lib/navishai`: Rails `log`, `storage`, and `tmp` directories, owned by `navishai` and linked from the matching paths in the release tree
- `/var/lib/navishai-runner`: runner state and run roots, owned by the separate `navishai-runner` user
- `/var/lib/supermemory`: Supermemory state, owned by `supermemory`
- a PostgreSQL 15 server with pgvector 0.8.6 and four databases named in `config/database.yml`

Build the three Go binaries from the pinned Go toolchain and install them in `/usr/local/bin`. Install the pinned Supermemory binary with `script/install_supermemory`, then copy it to `/usr/local/bin`. Bundle Rails with the locked gems and precompile assets with `SECRET_KEY_BASE_DUMMY=1`.

As an infrastructure bootstrap step, copy `ops/runner/execution.example.json` to `/etc/navishai/execution.json`. Its default keeps all live adapters off. Fix each adapter's maximum policy in the root-owned copy. For subscription modes, also install each approved CLI under `/opt/navishai/runtimes`, provision the existing subscription login under a credential home readable by `navishai-runner`, and configure the exact executable approval and egress profile. Direct OpenAI and Anthropic API-key connections use the built-in runner HTTPS client: they do not invoke the configured provider executable or read its credential home. Keep the shared adapter ceiling fields present for subscription compatibility. This file is not a routine Workspace provider-settings surface and contains no API key or subscription token. Set `NAVISHAI_CONTROL_PLANE_ADDRESS` to the public Rails HTTPS origin or another trusted route to it. The runner must reach `/webhooks/runner-events`; Rails does not need to expose the runner outside the private host network. Keep `NAVISHAI_RUNNER_STATE_PATH` and its parent writable by `navishai-runner`; the encrypted provider vault is stored at the same path with `.providers` appended.

Copy the units and environment examples from `ops/systemd` into the host's systemd and `/etc/navishai` directories. Replace every `change-me` value. Issue the runner certificate with SAN `127.0.0.1` when using the example loopback URL, or use a DNS SAN that matches `NAVISHAI_RUNNER_ADDRESS`. Link the release's `log`, `storage`, and `tmp` paths to their matching writable directories under `/var/lib/navishai`. Block inbound access to ports 6767 and 8081 in the host firewall; only local services should reach them. Then run:

```sh
systemctl daemon-reload
systemctl enable --now navishai-runner navishai-supermemory navishai-web navishai-jobs
```

The web unit runs `db:prepare` before boot. Do not run migrations from the jobs or runner users. Check `GET /up` through the reverse proxy and the runner's `GET /readyz` endpoint after each restart.

## Experimental Helm

The chart at `ops/helm/navishai` is cloud-neutral and does not install PostgreSQL, Supermemory, an ingress controller, or a certificate manager. Supply PostgreSQL 15 with pgvector 0.8.6, an ingress, storage classes, and immutable image references through your platform. Supply a customer-run Supermemory Local endpoint behind HTTPS with a certificate trusted by the Rails image; its stock binary has no TLS listener, so the platform must terminate TLS next to it. The chart disables service-account token mounts, uses the runtime-default seccomp profile, and blocks privilege gain for each application and init container.

Create the application secret with these keys:

- `SECRET_KEY_BASE`
- `NAVISHAI_DATABASE_PASSWORD`
- `NAVISHAI_RUNNER_SHARED_SECRET`
- `NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET`
- `NAVISHAI_SUPERMEMORY_API_KEY`

To enable OpenID Connect, also add `NAVISHAI_OIDC_ISSUER`, `NAVISHAI_OIDC_CLIENT_ID`, and `NAVISHAI_OIDC_CLIENT_SECRET` to this Secret. Omit all three to keep it off.

Create the runner TLS secret with `tls.crt`, `tls.key`, and `ca.crt`. The certificate DNS SAN must match `<release>-navishai-runner` in the target namespace. The runner image contains the disabled execution policy. To replace it, create a separate Secret with an `execution.json` key and set `runner.executionConfigSecret`; that immutable template supplies only approved binaries, credential-home paths, egress profiles, and policy ceilings. Provision any subscription login in runner-only storage with runner access. Keep API keys out of both Secrets; Workspace configuration relays them to the encrypted vault on the runner state volume. The chart opts into cleartext runner callbacks only for the cluster-internal Rails Service. Use a NetworkPolicy or service mesh to keep that route private, or replace it with an HTTPS service route and remove the opt-in in a deployment overlay. Set the database host, app host, image tags or digests, storage classes, replica counts, and resource limits in a private values file. Validate before install:

```sh
helm lint ops/helm/navishai -f production-values.yaml
helm template navishai ops/helm/navishai -f production-values.yaml >/dev/null
```

The chart keeps runner state on one persistent StatefulSet replica. Do not increase runner replicas until its state has moved to a shared, concurrency-safe service. Rails storage defaults to `ReadWriteMany`; use object storage instead when the platform cannot provide it.

## Boundaries

Deployment files do not set SMTP, Intercom, runtime subscription, provider API-key, or object-storage credentials. Supply only the integrations in use. Never place runtime provider credentials in Rails or the execution template. Subscription logins remain in deployment-provisioned runner homes; API keys are relayed through the signed in-app provider flow into the encrypted runner-local vault.

Use [OPERATIONS.md](./OPERATIONS.md) for backup, restore tests, and upgrade preflight. Use [RELEASE.md](./RELEASE.md) for release artifacts, checksums, signatures, and the SBOM.
