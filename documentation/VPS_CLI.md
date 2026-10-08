# Reset VPS CLI

## Upgrade in one command

On an installed VPS, this is the whole upgrade:

```sh
sudo navishai upgrade
```

It fetches `main` into `/root/navishai-source` (cloning it if missing), compares
it with the installed release and stops with "nothing to upgrade" when they match.
Otherwise it lists up to 20 new commits and asks to continue (`--yes` skips the
question). It then takes a full backup to a new
`/root/navishai-backups/<UTC date>-<time>-<old>-to-<new>` folder, upgrades with
writers stopped, restarts, and runs the same checks as `check` and `status`.
A failed upgrade restores that backup and stays stopped, as before.

Merged `main` is the reviewed code. To pin another reviewed commit instead, add
`--commit FULL_SHA`; that skips the fetch and the question. `--source` and
`--backup` still override the defaults.

### Move from the old `navishai-reset` command (one time)

Installs made before this change only have `navishai-reset`, whose installed
code cannot run the one-command upgrade. Run the new code once from a fresh
checkout; it upgrades and then renames the command:

```sh
sudo git clone https://github.com/glnarayanan/navishai.git /root/navishai-source
sudo /root/navishai-source/bin/navishai-vps upgrade
```

After a successful upgrade (or when already current), it links
`/usr/local/bin/navishai`, points the two startup services at it, reloads
systemd and removes `/usr/local/bin/navishai-reset`. From then on, use
`sudo navishai upgrade`. Any later operator command finishes the rename if an
upgrade was made with the old command. The old `/root/navishai-reset-source`
checkout and `/root/navishai-reset-backups` stay untouched; delete them under
your own retention policy.

Only the command and default folders changed. Systemd units
(`navishai-reset.service`, `navishai-reset-check.timer`), managed paths, the
Compose project, volumes and labels keep the `navishai-reset` name, because
renaming them would mean moving the database volumes.

## Fresh replacement

`bin/navishai-vps` installs the reset from one reviewed Git commit. It does not
install host packages or convert old helpdesk data. First remove only the verified
old install with [legacy uninstall](./LEGACY_UNINSTALL.md); backup is optional for
the owner's disposable test data. No broad Docker/system prune is needed.

Use a reviewed full commit SHA from `main`, not local edits. On the VPS:

```sh
sudo git clone https://github.com/glnarayanan/navishai.git /root/navishai-source
# Replace this value with the reviewed 40-character commit SHA.
RESET_COMMIT=APPROVED_FULL_COMMIT_SHA
sudo git -C /root/navishai-source checkout --detach "$RESET_COMMIT"
sudo /root/navishai-source/bin/navishai-vps doctor
sudo /root/navishai-source/bin/navishai-vps install \
  --source /root/navishai-source --commit "$RESET_COMMIT"
sudo navishai status
```

### Guided setup and resume

Install asks for domain, ACME contact email, SMTP server/port/user/password/from,
initial Owner email/password/confirmation, and organisation/workspace names and
slugs. It corrects invalid input and shows nonsecret choices before asking `yes`.
Passwords use hidden terminal reads. Ctrl-C, EOF or rejecting review leaves
installed state unchanged. You do not need an IP address or an edited `.env`.
SMTP must support authenticated STARTTLS with a trusted certificate, usually on
port 587. Enter decimal ports without leading zeroes; implicit-TLS-only SMTP is
not this application's mail contract. Setup does not send a test email.

The CLI creates distinct random database secrets, a Rails secret and a two-hour
bootstrap token in private internal config. After gated HTTPS startup, it creates
the chosen Owner through the existing bootstrap service in the running web
container and records an attributable audit in the same transaction. Account input
goes through stdin, not command arguments; the clear Owner password does not enter
config. This runtime write does not launch one-off maintenance alongside live
writers. Existing Owners cannot be recreated. Public registration stays off; no
default password is supplied.

If install reaches owned state but a later step fails, correct the named cause and
run `sudo navishai install --resume`. Resume reads the protected installed
release and needs no source checkout or commit argument. An optional `--commit`
must match that release; setup refuses a mismatch before asking account questions
and rechecks the release under the mutation lock after consent. Resume retains
domain, SMTP and secrets; it asks for account choices without saving passwords.
Do not delete data or rerun fresh install. If the protected token is inactive:

```sh
sudo navishai renew-bootstrap
sudo navishai install --resume
```

Renewal stops writers, checks native bootstrap eligibility and creates a new
private two-hour token. It refuses a completed bootstrap without changing config.
If failure occurred before any installed state, use normal install again.

Older CLI releases still require the original arguments for resume:

```sh
sudo /root/navishai-source/bin/navishai-vps install --resume \
  --source /root/navishai-source --commit "$RESET_COMMIT"
```

Owner refusals now distinguish inactive tokens, malformed input, invalid account
fields and database/audit errors. Only fixed field names reach the terminal; no
values, exception text, SQL or backtraces do. Account/audit failures roll back the
whole account transaction. Renew only an inactive token, not a validation error.

Automation must opt in with `--non-interactive --answers /root/private-answers.json`.
The file must be root-owned, mode 0600, single-link, at most 32 KiB and inside a
root-controlled directory. Supply exactly these string keys, with no duplicates:
`host`, `acme_email`, `smtp_server`, `smtp_port`, `smtp_user`, `smtp_password`,
`smtp_from`, `owner_email`, `owner_password`, `owner_password_confirmation`,
`organization_name`, `organization_slug`, `workspace_name`, `workspace_slug`.
The explicit flag supplies consent instead of an interactive review. Keep secrets
out of shell arguments/history and remove the answers file under your retention
policy after use. Resume accepts the same answer schema but retains installed
domain/SMTP config. SMTP credentials cannot contain control characters, single
quotes or backslashes: the literal dotenv contract refuses those values rather
than changing them. Owner passwords require 12 characters and at most 72 bytes.

Advanced automation may still generate an `init-env` template and install with
`--env PRIVATE_FILE`; fill its SMTP fields privately. That path does not collect
or create an Owner. Use the protected HTTPS bootstrap before token expiry, or
renew it with the command above. Manual config is not the default install path.
All six model/target registries default to `[]`. Filling a registry still requires
its own workspace approval and human disclosure consent.

### Host prerequisites

Root on Linux with systemd, a **local Unix-socket Docker Engine**, and Compose
2.39.4 or later. Required commands: Bash, Git, jq, curl, getent, awk, OpenSSL,
GNU tar/coreutils, flock, findmnt, nsenter, ip, ss, iptables/ip6tables and both save/restore pairs. Both kernel
filter families must work; IPv4-only rules are not a fallback. The host needs disk
space for builds, retained releases/images and full backups. `doctor` checks local
tools and Docker, not DNS, public access, SMTP delivery or enough disk space.

Normal hosts need one public IPv4 on an up, non-tailnet interface with a main-table
default route. The CLI reads native JSON addresses/routes, excludes private,
loopback, carrier-grade NAT, link-local and tailnet addresses, then validates the
selected address's outbound route. No unique safe choice means refusal, not a guess.
An optional `--public-listen-address IPV4` override must pass the same assigned
address and route checks. Use it only for a deliberate multihomed topology.

Desired config stores `auto`, not the discovered IP, interface or container IDs.
Every startup and Compose call derives the current host address. `check` stops
writers if actual proxy bindings are stale or unsafe; gated `start` recreates them
on the current address. Reboot/address changes need no env edits in auto mode.
An explicit override remains deliberate config on that host and refuses when
stale; destination `recover` defaults back to auto.

Caddy publishes TCP 80/443 on the derived public address and 443 on 127.0.0.1 for
direct, trusted local HTTPS checks. There is no wildcard or public IPv6 publication;
an origin AAAA record must not send clients to an unserved interface. These endpoints
and host loopback 3000 must be free. Tailnet-only listeners on 443 can stay. Allow Docker
image/build downloads, Caddy ACME and public SMTP traffic under the owner's host
policy. Do not publish PostgreSQL. A host with a shared existing proxy or blocked
ports needs a separate reviewed topology; this CLI does not replace that proxy or
change its firewall. No host package or network setup command is guessed here.

Startup requires public IPv4 hostname resolution and trusted direct-loopback TLS.
DNS may point through Cloudflare or another proxy; the CLI does not confuse its
edge IPs with the host's bind address. The operator must still configure and verify
the proxy's origin routing, public DNS/ports and SMTP delivery. NAT-only hosts with
no assigned public IPv4, IPv6-only ingress and shared public proxies need a separate
reviewed topology. Automatic discovery does not certify arbitrary hosts.

Install/upgrade inspect the exact configured PostgreSQL/Caddy digest references
and pull only a missing image. Docker/API inspection errors stop the operation.
Startup and maintenance use `--pull never`; builds run only in install/upgrade.
Compose 2.39.4's `pull --policy missing` does not skip cached tag-plus-digest refs,
so the CLI does not use it. Pins stay unchanged. A cold build or missing pin still
needs downloads; cached operation is not a general offline-install guarantee.

Before deletion/install, collect only read-only host facts (no env/secret dump):

```sh
cat /etc/os-release
docker --version; docker compose version; systemctl --version
sudo docker compose ls --all
sudo ss -lntp '( sport = :80 or sport = :443 or sport = :3000 )'
ip -4 route; ip -6 route
ip -4 route get 1.1.1.1; ip -brief address show
```

The old uninstall preview supplies the exact source SHA, CLI/current release,
Compose config paths, container IDs, volume names and network IDs. If it cannot
prove a project/layout, stop and share that refusal and the read-only inventory,
not private environment contents. It does not run an unknown old CLI for a version.

### Recover a wildcard-bind partial install (historical)

The old installer isolated public ingress in
[`fe5de56`](https://github.com/glnarayanan/navishai/commit/fe5de56b41880dd409bc425ba455ebb18af5d331).
The first reset CLI lost `NAVISHAI_PUBLIC_LISTEN_ADDRESS` and published wildcard
80/443. The owner's journal confirmed `0.0.0.0:443: address already in use` while
Tailscale listened only on tailnet addresses. Web/jobs had started; failure handlers
then stopped them. This was a deployment regression, not a Cloudflare diagnosis.
The final historical installer prompted hostname/bind IP and accepted protected
SMTP answers; it did not prove automatic discovery or complete interactive SMTP/
Owner setup. Those are the new supported defaults, not invented historical claims.

Keep Tailscale and its access/services unchanged. A listener does not prove Serve
or Funnel is configured. If needed, record those settings with read-only
`sudo tailscale serve status` and `sudo tailscale funnel status`. Do not reset them.

After review of the fix, use its source CLI for one backed-up upgrade. The old
managed CLI cannot parse the new option. Do not add the key to its env first,
edit an immutable release, delete installed data or rerun install:

```sh
sudo git -C /root/navishai-source fetch origin
FIXED_COMMIT=REVIEWED_FULL_FIX_SHA
sudo git -C /root/navishai-source checkout --detach "$FIXED_COMMIT"
sudo install -d -m 700 /root/navishai-backups
sudo /root/navishai-source/bin/navishai-vps upgrade \
  --source /root/navishai-source --commit "$FIXED_COMMIT" \
  --backup /root/navishai-backups/before-ingress-fix
# Only after upgrade succeeds, restore the generated service's active state.
sudo systemctl start navishai-reset.service navishai-reset-check.timer
sudo navishai check
sudo navishai status
```

No IP input is required. The backup directory must be new. Upgrade stops writers,
saves the full old recovery point, then writes desired `auto` to private config
and switches to the new release. Failure restores saved code/data/config and
stays stopped. Do not
start the old wildcard release after a failed upgrade; retain the error and backup.
The certificate/hostname checks, runtime credentials and both namespace policy
families remain in force. No script stops Tailscale or changes host interfaces.

## Commands after install

```sh
sudo navishai upgrade
sudo navishai status
sudo navishai check
sudo navishai stop
sudo navishai start
sudo install -d -m 700 /root/navishai-backups
sudo navishai backup --output /root/navishai-backups/point-001

# Pinned alternative to the one-command upgrade; the backup folder must be new.
sudo navishai upgrade --commit NEW_REVIEWED_FULL_COMMIT_SHA \
  --backup /root/navishai-backups/pre-upgrade-001

# Explicit restore destroys current reset data. Inspect the backup first.
sudo sha256sum /root/navishai-backups/point-001/CHECKSUMS
sudo navishai restore --from /root/navishai-backups/point-001 \
  --confirm-restore DISPLAYED_CHECKSUMS_SHA256
sudo navishai start

# Preview; repeat with its digest only when destruction is intended.
sudo navishai cleanup
sudo navishai cleanup --apply --confirm-destroy DISPLAYED_PLAN_SHA256
```

Backup pauses writers and resumes them only through gated start after publication.
Upgrade keeps writers stopped from backup through migrations. Failed upgrade
restores the full saved code/data/config point and remains stopped; inspect the
failure before `start`. Successful restore also leaves writers stopped. No downward
migration or automatic retry runs. See [recovery](./VPS_RECOVERY.md) for archive,
role, volume and file rules. Backups contain plaintext secrets/data: use a separate
approved encryption, off-host retention and deletion policy.

Cleanup removes only verified reset containers, four volumes, two networks, managed
code/config/state, CLI symlink and exact units. It refuses foreign/shared mounts or
resources and stops on failure. It leaves images, host packages, the source checkout,
input env file and external backups. If install fails before Docker work, it removes
only its new staging roots. Later failures keep an `installing` receipt so the source
CLI can preview/clean that exact partial install even without generated units.

### Move or recover onto another VPS

First upgrade the source to this portable CLI, then take a full backup. Older
wildcard releases cannot supply clean-host recovery: upgrade the source before
migration. Securely copy the complete private backup onto the destination; the CLI
does not transfer or encrypt it. Keep the source stopped during cutover. Two active
copies can run duplicate jobs; a backup alone does not coordinate them.

On the destination, prepare the host prerequisites above, fetch/review this CLI
and make the backup parent/files root-owned with their original 0700/0600 modes.
Do not run fresh `install` or create empty data first. Target paths and project
resources must be absent. Inspect the backup's manifest/checksums privately:

```sh
sudo /root/navishai-source/bin/navishai-vps doctor
sudo sha256sum /root/navishai-backups/migration-point/CHECKSUMS
sudo /root/navishai-source/bin/navishai-vps recover \
  --from /root/navishai-backups/migration-point \
  --confirm-restore DISPLAYED_CHECKSUMS_SHA256
# Restore leaves writers stopped. Point DNS/proxy origin at this destination.
sudo systemctl start navishai-reset.service navishai-reset-check.timer
sudo navishai check
sudo navishai status
```

Recovery validates the full backup, creates only owned destination paths/resources,
restores exact data/secrets/roles/history and registers local units. It rebinds
receipt paths, defaults desired ingress to `auto` and recreates container identities.
It never restores the source IP/interface/container identity as runtime state.
Before serving, gated startup checks destination DNS, trusted loopback HTTPS,
restricted roles and both namespace policies. No fresh Owner or secret rotation
runs during migration. Same-install `restore` still keeps byte-exact desired config.

If destination recovery fails after creating its receipt, fix the named cause and
repeat `recover --resume` with the same reviewed release, backup and checksum
consent. It checks the unfinished `recovering` receipt and owned resources, not
arbitrary existing installations. Data restore repeats; writers stay stopped.
If failure left no installed roots, repeat ordinary `recover`. No deletion or
immutable-release edit is part of either retry.

## Ownership and startup

The CLI owns `/opt/navishai-reset`, `/etc/navishai-reset`, `/var/lib/navishai-reset`,
the `/usr/local/bin/navishai` command link and the exact `navishai-reset` Compose
project. `current` points to an immutable
`releases/<full-git-sha>` with `SOURCE_COMMIT`. Private configuration is
`/etc/navishai-reset/env`; state and the mutation lock live under the state path.
An explicit managed root supports isolated tests, never guessed host cleanup.
All resources carry `com.navishai.owner=navishai-reset`. CLI source and release
inputs are operator-reviewed code, not uploaded corpus content.

The optional production override leaves the manual three-service baseline intact.
It adds Caddy for HTTPS and an environment-empty, capability-dropped `app-net`
namespace holder using the existing app image. Web/jobs share that private
namespace. The host CLI applies and verifies IPv4/IPv6 OUTPUT rules there before
starting either process. The rules permit only required local/DNS/database paths,
reply traffic and public destinations; application endpoint/consent gates remain.
The CLI does not edit host firewall rules or sysctls. Docker still manages its own
bridge/NAT rules; the private proofs keep those inside disposable namespaces.

Docker does not automatically restart managed containers. A systemd startup path
owns ordering after boot/daemon restart: create PostgreSQL/holder, bind policy to
their actual identities/addresses, apply/check both families, then start writers
and HTTPS. A changed or partial guard must leave writers stopped. An operator with
host root/Docker control can still bypass these rules; this is not a root sandbox.

Web/jobs use `up --no-start --no-deps --force-recreate` before inspection. This
creates stopped replacements without reconciling the guarded PostgreSQL/holder
dependencies. Compose 2.39.4 does not support `create --no-deps`. Runtime namespace,
privilege and policy checks still precede the separate `start web jobs` command.

Only PostgreSQL receives the fixed local bootstrap administrator `navishai_admin`.
It creates all four lab databases owned by `navishai_setup`. Preparation and runtime
roles both have no superuser/create-database/create-role/replication/bypass-RLS
flags, and use separate passwords. Runtime gets native DML/sequence grants only.
Transient preparation receives its own secret; persistent web/jobs receive neither
bootstrap nor preparation credentials.

Backup stops all writers and captures all four databases, owners/ACLs/sequences,
exact release/images, config/secrets/state, Rails files and proxy certificates as
one recovery point. Private permissions, strict manifests/checksums, safe archive
members and atomic publication apply. The helper leaves writers stopped; only
gated start resumes a normal backup. Upgrade stays stopped through backup and
migration and restores old code/data/config on failure, not downward migrations.
Restore leaves writers stopped even on success.

An optional final `recovery-images.yaml` stores only the five service image IDs as
JSON-valid YAML. Docker save/load preserves image IDs, not upstream RepoDigest
aliases. Restore uses this scoped overlay; upgrade backs it up, then removes it
before candidate commands. It never rewrites immutable release/Compose files.

## Done checks and limits

Focused core checks pass 36 tests / 357 assertions; guided setup passes 11 / 235,
with no failures, errors or skips. The one-command upgrade tests use a local Git
origin to cover the up-to-date no-op, the commit list and refusal without a
terminal or `--yes`, auto-named backups, post-upgrade check/status, the pinned
path without fetching, and the one-time command rename with foreign-link and
foreign-unit refusal. Earlier checks cover native terminal hiding/cancellation,
invalid/protected answers, stdin-only account input, lock ordering, retained resume
config, automatic discovery, ambiguity/stale override refusal, exact endpoints,
byte-exact upgrade rollback and unfinished-destination ownership. Bash/Ruby syntax,
all 388 Ruby files of native style and diff checks pass. Final seeded operations
pass 85 tests / 1,011 assertions. Sequential `bin/ci` passes 718 Rails tests /
11,424 assertions and 71 browser tests / 3,562 assertions in 24m20.20s. Final
operations and the frozen proof recheck the last setup fixes after that broad run.

The fast native ingress proof reproduces wildcard `EADDRINUSE`, then passes with
exact public/loopback ports, reachable IPv4/IPv6 tailnet listeners and refusal of
occupied endpoints. The [joined proof](./VPS_CLI_PROOF.md) records exact frozen
source hashes and separates earlier static-binding results from the current
automatic/guided/portable source. The current full run returns exit 0 / `CLEAN`:
partial-install automatic upgrade, chosen Owner setup, complete restore and
committed-mutation rollback, empty different-address destination recovery/resume,
address-change reconciliation and daemon restart. Eighteen pre-start inspections
and 175 source maintenance windows pass. Separate kernel/PG proof scope remains
in [policy](./VPS_POLICY.md) and [recovery](./VPS_RECOVERY.md).

Host-side proof builders disable both Docker `iptables` and `ip6tables` manipulation.
Native fixture/unit tests alone cannot certify public ingress, ACME/DNS, SMTP/OIDC,
the owner's firewall or storage, live recovery or customer/model quality.

Owner-specific inputs remain hostname/DNS, access to public 80/443, SMTP, and a
root-controlled Linux/systemd Docker host with the required namespace/firewall tools.
The owner attempted the initial reset install; its public-bind failure is recorded
above. The owner then ran the ingress fix: upgrade passed runtime/schema/policy
and direct-local HTTPS gates and reached guided Owner setup. That setup refused
with an unclassified error; renewal succeeded, but bare resume then failed on the
old missing-argument check. The Owner-resume follow-up has not run on that VPS.
No agent VPS, provider or paid call ran.
