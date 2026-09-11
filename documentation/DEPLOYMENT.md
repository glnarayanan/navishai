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

For a first Owner, also set `NAVISHAI_BOOTSTRAP_TOKEN` to a random value of at least 32 bytes and `NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT` to a future ISO 8601 UTC time before starting Rails. The setup page accepts the token once. After the first Owner is created, remove both values from `.env` and recreate `web` and `jobs`. An expired, missing, or malformed expiry disables setup; renewal is safe only while the installation has no users, organisations, or installation state.

Compose binds Rails to port 3000 by default. Set `NAVISHAI_HTTP_PORT` to change the host port. Rails, jobs, and Supermemory share one container network namespace so Rails can use Supermemory's supported loopback HTTP endpoint. They remain separate processes and images. The runner has its own container and receives no Docker socket. The non-root application containers drop Linux capabilities and cannot gain new privileges. The control network is internal. Put the reverse proxy on the edge side and send the original HTTPS host. Rails rejects every Host other than `NAVISHAI_APP_HOST`; only `/up` skips that check for local health probes.

Supermemory needs its first-boot local model setup. Keep `NAVISHAI_MEMORY_PENDING=1` after infrastructure setup; the installer leaves Supermemory stopped and the checklist marks Memory as deferred. In a trusted private terminal, run the installed release's Supermemory container interactively, complete only its documented prompt, and copy the generated `sm_...` key directly into a root-owned `0600` file. Do not scrape service logs, shell history, screenshots, or diagnostic bundles for that key. Create a separate root-owned `0600` answer file containing only `NAVISHAI_SUPERMEMORY_API_KEY_FILE=/path/to/key`, then run `NAVISHAI_ANSWERS_FILE=/path/to/answers navishai configure memory`. This starts Supermemory, web, and jobs but proves only configuration; an Owner must confirm scoped indexing and retrieval before treating Memory as ready. The pinned opaque `server-v0.0.8` has no documented unattended key bootstrap/export interface, and current upstream guidance says its prompt may require an external model-provider credential. That credential may incur provider cost and must stay outside Rails and ordinary logs. The Lite build has a 10,000-document licence cap.

The current disposable-host installer record is in [INSTALLER_ACCEPTANCE_EVIDENCE.md](./INSTALLER_ACCEPTANCE_EVIDENCE.md). It does not prove public ACME, live providers, ClamAV, or an application/schema upgrade.

The local-candidate installer answer file requires `NAVISHAI_APP_HOST` and supports `NAVISHAI_SUPERMEMORY_API_KEY_FILE` only as a secret reference. It must name an owner-readable, regular, non-symlink file with no group or other permissions and one safe printable token value. The installer never sources answer files. `navishai setup` retains Memory as pending; only `navishai configure memory` clears that state after the isolated first-boot procedure. `navishai setup` validates a public DNS hostname, then prints the selected hostname, ports 80 and 443, private configuration, installer metadata, persistent Docker volumes, and service changes before it writes host state. An interactive admin must confirm; a noninteractive run must set `NAVISHAI_SETUP_ACCEPT=yes` after reviewing that summary. On infrastructure startup, it prints the HTTPS first-Owner address and the explicit token-reveal command without printing the token. A rerun accepts only the same verified release and retains the existing environment and runner TLS. This is local-candidate behavior, not a published installer or proof of public HTTPS.

`ops/installer/bootstrap` accepts a local candidate path or an HTTPS candidate URL. For a URL, set `NAVISHAI_CANDIDATE_SHA256_FILE` to an owner-only `0600` regular file holding the expected SHA-256 value that you obtained from the release publisher through a channel you already trust. The bootstrap validates that file and the presence of `curl` before it transfers anything, downloads to a `.part` file over HTTPS only, follows only HTTPS redirects, resumes an interrupted transfer with a byte range on rerun, restarts from the beginning when the server cannot serve ranges, removes a partial file whose checksum does not match, and renames the verified file into place before it invokes setup. A destination that already matches the checksum is reused without a download. This is integrity against an operator-supplied digest, not publisher authentication: no release-signing identity or public distribution endpoint exists yet.

Configure system mail without editing the managed environment. Create a root-owned `0600` answer file and a separate root-owned `0600` password file, then run `NAVISHAI_ANSWERS_FILE=/path/to/answers navishai configure system-mail`. The answer file has `NAVISHAI_SYSTEM_SMTP_ADDRESS`, `_PORT`, `_USER_NAME`, `_PASSWORD_FILE`, and `_FROM`; the password itself appears only in the referenced file. The command validates all values before replacing only the five system-mail fields atomically, recreates web and jobs, and reports that SMTP acceptance remains untested. It does not configure shared-inbox/customer-reply SMTP or send email.

Keep `.env` and `ops/secrets/runner` outside source control. Back up both through the host's secret and backup systems. To rotate runner TLS, stop `web`, `jobs`, and `runner`, remove the three generated runner TLS files, run `script/generate_runner_tls`, then restart those services. Rotating the shared secret also requires one coordinated stop and restart.

To enable OpenID Connect, set the three optional `NAVISHAI_OIDC_*` values in `.env`. Keep the client secret in the host secret store. Leave all three blank to keep single sign-on off.

Optional S3-compatible object storage, SearXNG, and ClamAV remain external. Configure them only when used; the default stack has no general runner egress. Public-web research is off until `.env` sets `NAVISHAI_WEB_SEARCH_PROVIDER` to `searxng` with `NAVISHAI_SEARXNG_URL`, or to `exa` or `tavily` with the matching API key; Compose passes those values to the runner container only. To scan attachments, run a ClamAV daemon on the private `control` network or the host. Create a root-owned `0600` answer file with `NAVISHAI_ATTACHMENT_SCANNER=clamd` and `NAVISHAI_CLAMD_ADDRESS` (`tcp://host:port` or `unix:///path`), then run `NAVISHAI_ANSWERS_FILE=/path/to/answers navishai configure scanner`. The command atomically replaces only scanner settings and restarts web and jobs. It proves configuration, not daemon reachability or a real scan. Files remain quarantined until the application receives an explicit clean result. Without a scanner every attachment stays quarantined.

The checked-in runner execution policy starts with all live adapters disabled. `NAVISHAI_RUNNER_EXECUTION_CONFIG_PATH` selects the deployment-owned infrastructure template, `NAVISHAI_RUNTIME_EXECUTABLES_PATH` mounts approved CLI files at `/opt/navishai/runtimes`, and `NAVISHAI_RUNTIME_STATE_PATH` mounts pre-existing subscription credential homes at `/var/lib/navishai/runtime`. Keep those host directories and credential files out of source control and make the homes readable by the container's runner UID; the example mounts them read-only because subscription login is completed on the host, outside NavishAI. A live adapter also needs an exact executable approval and a deployment-owned subordinate user/network namespace egress profile in the immutable policy ceiling. Compose does not create those host security boundaries. Leave the adapter disabled until the namespace files, firewall or allowlisting proxy, TLS roots, executable, and any subscription login are present. The runner sends signed events back to Rails over the private, internal Compose network; the explicit cleartext opt-in applies only to that link. Its admission state, pending event outbox, runtime-test state, and encrypted provider vault are writable and persistent on `runner_data`. Workspace Owners and Admins then connect API-key or existing-login providers in **Providers** without editing the policy or restarting the runner.

## Native Linux

The runner image bundles LibreOffice Writer for legacy `.doc` imports. Native Debian/Ubuntu runner hosts need `apt-get install --no-install-recommends libreoffice-writer`. Keep that package and its dependencies current with distribution security updates; rebuild the runner image for container updates. The image's `/usr/share/navishai/runner-packages.txt` records the installed OS package versions separately from the Ruby SBOM.

Conversion uses the fixed `navishai-document` helper through `navishai-exec` on Linux amd64. The helper calls LibreOfficeKit directly, keeping all socket operations denied. Install build-only `libreofficekit-dev`, then compile with `cc -O2 -Wall -Wextra -Werror -o navishai-document runner/cmd/navishai-document/main.c -ldl` and install the helper beside `navishai-exec`. It has no network access or provider credentials and uses a fresh profile with macros and link updates disabled. The private conversion directory defaults to `NAVISHAI_RUNNER_STATE_PATH` with `.documents` appended; `NAVISHAI_DOCUMENT_WORK_ROOT` can override it. Keep it outside runtime-readable roots and credential homes, writable only by the runner user. Conversion is bounded and temporary files are removed after each request. A missing converter or unsupported isolation host makes DOC imports unavailable without disabling other imports or runner work. The manual CI workflow builds the runner image, checks Writer and the three helper binaries, then converts the repository DOC fixture inside that image.

The supported layout is:

- `/opt/navishai/current`: an immutable release tree with bundled gems and compiled assets
- `/etc/navishai`: root-owned environment and runner TLS files, mode `0750` for the directory and `0640` or tighter for files
- `/var/lib/navishai`: Rails `log`, `storage`, and `tmp` directories, owned by `navishai` and linked from the matching paths in the release tree
- `/var/lib/navishai-runner`: runner state and run roots, owned by the separate `navishai-runner` user
- `/var/lib/supermemory`: Supermemory state, owned by `supermemory`
- a PostgreSQL 16 server with pgvector 0.8.6 and four databases named in `config/database.yml`

Build the three Go binaries from the pinned Go toolchain and install them in `/usr/local/bin`. Install the pinned Supermemory binary with `script/install_supermemory`, then copy it to `/usr/local/bin`. Bundle Rails with the locked gems and precompile assets with `SECRET_KEY_BASE_DUMMY=1`.

As an infrastructure bootstrap step, copy `ops/runner/execution.example.json` to `/etc/navishai/execution.json`. Its default keeps all live adapters off. Fix each adapter's maximum policy in the root-owned copy. For subscription modes, also install each approved CLI under `/opt/navishai/runtimes`, provision the existing subscription login under a credential home readable by `navishai-runner`, and configure the exact executable approval and egress profile. Direct OpenAI and Anthropic API-key connections use the built-in runner HTTPS client: they do not invoke the configured provider executable or read its credential home. Keep the shared adapter ceiling fields present for subscription compatibility. This file is not a routine Workspace provider-settings surface and contains no API key or subscription token. Set `NAVISHAI_CONTROL_PLANE_ADDRESS` to the public Rails HTTPS origin or another trusted route to it. The runner must reach `/webhooks/runner-events`; Rails does not need to expose the runner outside the private host network. Keep `NAVISHAI_RUNNER_STATE_PATH` and its parent writable by `navishai-runner`; the encrypted provider vault is stored at the same path with `.providers` appended.

Copy the units and environment examples from `ops/systemd` into the host's systemd and `/etc/navishai` directories. Replace every `change-me` value. Issue the runner certificate with SAN `127.0.0.1` when using the example loopback URL, or use a DNS SAN that matches `NAVISHAI_RUNNER_ADDRESS`. Link the release's `log`, `storage`, and `tmp` paths to their matching writable directories under `/var/lib/navishai`. Block inbound access to ports 6767 and 8081 in the host firewall; only local services should reach them. Then run:

```sh
systemctl daemon-reload
systemctl enable --now navishai-runner navishai-supermemory navishai-web navishai-jobs
```

The web unit runs `db:prepare` before boot. Do not run migrations from the jobs or runner users. Check `GET /up` through the reverse proxy and the runner's `GET /readyz` endpoint after each restart.

## Experimental Helm

The chart at `ops/helm/navishai` is cloud-neutral and does not install PostgreSQL, Supermemory, an ingress controller, or a certificate manager. Supply PostgreSQL 16 with pgvector 0.8.6, an ingress, storage classes, and immutable image references through your platform. Supply a customer-run Supermemory Local endpoint behind HTTPS with a certificate trusted by the Rails image; its stock binary has no TLS listener, so the platform must terminate TLS next to it. The chart disables service-account token mounts, uses the runtime-default seccomp profile, and blocks privilege gain for each application and init container.

Create the application secret with these keys:

- `SECRET_KEY_BASE`
- `NAVISHAI_DATABASE_PASSWORD`
- `NAVISHAI_RUNNER_SHARED_SECRET`
- `NAVISHAI_RUNNER_PROVIDER_VAULT_SECRET`
- `NAVISHAI_SUPERMEMORY_API_KEY`

To enable OpenID Connect, also add `NAVISHAI_OIDC_ISSUER`, `NAVISHAI_OIDC_CLIENT_ID`, and `NAVISHAI_OIDC_CLIENT_SECRET` to this Secret. Omit all three to keep it off. To use a hosted search provider, add `NAVISHAI_EXA_API_KEY` or `NAVISHAI_TAVILY_API_KEY` to the same Secret and set `webSearch.provider`; only the runner pod reads those keys.

Create the runner TLS secret with `tls.crt`, `tls.key`, and `ca.crt`. The certificate DNS SAN must match `<release>-navishai-runner` in the target namespace. The runner image contains the disabled execution policy. To replace it, create a separate Secret with an `execution.json` key and set `runner.executionConfigSecret`; that immutable template supplies only approved binaries, credential-home paths, egress profiles, and policy ceilings. Provision any subscription login in runner-only storage with runner access. Keep API keys out of both Secrets; Workspace configuration relays them to the encrypted vault on the runner state volume. The chart opts into cleartext runner callbacks only for the cluster-internal Rails Service. Use a NetworkPolicy or service mesh to keep that route private, or replace it with an HTTPS service route and remove the opt-in in a deployment overlay. Set the database host, app host, image tags or digests, storage classes, replica counts, and resource limits in a private values file. Validate before install:

```sh
helm lint ops/helm/navishai -f production-values.yaml
helm template navishai ops/helm/navishai -f production-values.yaml >/dev/null
```

The chart keeps runner state on one persistent StatefulSet replica. Do not increase runner replicas until its state has moved to a shared, concurrency-safe service. Rails storage defaults to `ReadWriteMany`; use object storage instead when the platform cannot provide it.

## Boundaries

Deployment files do not set shared-inbox SMTP, Intercom, runtime subscription, provider API-key, or object-storage credentials. Supply only the integrations in use. To send system mail such as invitations and password resets, set `NAVISHAI_SYSTEM_SMTP_ADDRESS`, `_PORT`, `_USER_NAME`, `_PASSWORD`, and `_FROM` in the protected deployment environment. NavishAI requires STARTTLS with certificate verification. This system-mail transport is separate from shared-inbox/customer-reply SMTP. Missing or invalid system-mail settings leave the app usable but reject mail delivery clearly. The checklist can show configured, but configuration is not a delivery test. Never place runtime provider credentials in Rails or the execution template. Subscription logins remain in deployment-provisioned runner homes; API keys are relayed through the signed in-app provider flow into the encrypted runner-local vault.

Use [OPERATIONS.md](./OPERATIONS.md) for backup, restore tests, and upgrade preflight. Use [RELEASE.md](./RELEASE.md) for release artifacts, checksums, signatures, and the SBOM.

Workspace connectors require `NAVISHAI_INTEGRATION_ENCRYPTION_KEY` and `NAVISHAI_INTEGRATION_ENCRYPTION_SALT`; keep both in the deployment secret manager and pair them with database backups. Configure each provider’s OAuth client ID, secret, and exact redirect URI separately. Service credentials and personal OAuth tokens are encrypted in Rails; AI-provider secrets remain on the runner. See [Development](./DEVELOPMENT.md#workspace-connectors-and-personal-connections) for connector and deployed personal-account setup.
