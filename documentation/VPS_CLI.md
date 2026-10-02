# Reset VPS CLI

## Fresh replacement

`bin/navishai-vps` installs the reset from one reviewed Git commit. It does not
install host packages or convert old helpdesk data. First remove only the verified
old install with [legacy uninstall](./LEGACY_UNINSTALL.md); backup is optional for
the owner's disposable test data. No broad Docker/system prune is needed.

New CLI work needs review before deployment. Use an approved full commit SHA that
contains this CLI, not a pre-CLI `main` or local edits. On the VPS:

```sh
sudo git clone https://github.com/glnarayanan/navishai.git /root/navishai-reset-source
# Replace this value with the reviewed 40-character commit SHA.
RESET_COMMIT=APPROVED_FULL_COMMIT_SHA
sudo git -C /root/navishai-reset-source checkout --detach "$RESET_COMMIT"
sudo /root/navishai-reset-source/bin/navishai-vps doctor
sudo /root/navishai-reset-source/bin/navishai-vps init-env \
  --host support.example.com --acme-email owner@example.com \
  --output /root/navishai-reset.env
sudoedit /root/navishai-reset.env
# Fill all five SMTP fields; replace hostname/email above with your own.
sudo /root/navishai-reset-source/bin/navishai-vps install \
  --source /root/navishai-reset-source --commit "$RESET_COMMIT" \
  --env /root/navishai-reset.env
sudo navishai-reset status
```

Run install within the generated bootstrap token's two-hour expiry, or set a new
explicit expiry in that private file. The CLI prints no secrets. Use the private
token to create the first Owner through HTTPS; public registration stays off.
All six model/target registries default to `[]`. Filling a registry still requires
its own workspace approval and human disclosure consent.

### Host prerequisites

Root on Linux with systemd, a **local Unix-socket Docker Engine**, and Compose
2.39.4 or later. Required commands: Bash, Git, jq, curl, OpenSSL, GNU tar/coreutils,
flock, findmnt, nsenter, iptables/ip6tables and both save/restore pairs. Both kernel
filter families must work; IPv4-only rules are not a fallback. The host needs disk
space for builds, retained releases/images and full backups. `doctor` checks local
tools and Docker, not DNS, public access, SMTP delivery or enough disk space.

The hostname's A/AAAA records must reach this VPS. Public inbound TCP 80/443 must
reach Caddy without another listener. Host loopback 3000 must be free. Allow Docker
image/build downloads, Caddy ACME and public SMTP traffic under the owner's host
policy. Do not publish PostgreSQL. A host with a shared existing proxy or blocked
ports needs a separate reviewed topology; this CLI does not replace that proxy or
change its firewall. No host package or network setup command is guessed here.

## Commands after install

```sh
sudo navishai-reset status
sudo navishai-reset check
sudo navishai-reset stop
sudo navishai-reset start
sudo install -d -m 700 /root/navishai-reset-backups
sudo navishai-reset backup --output /root/navishai-reset-backups/point-001

# Fetch and review a new full SHA first; do not reuse an existing release directory.
sudo git -C /root/navishai-reset-source fetch origin
NEW_COMMIT=NEW_REVIEWED_FULL_COMMIT_SHA
sudo navishai-reset upgrade --source /root/navishai-reset-source \
  --commit "$NEW_COMMIT" --backup /root/navishai-reset-backups/pre-upgrade-001

# Explicit restore destroys current reset data. Inspect the backup first.
sudo sha256sum /root/navishai-reset-backups/point-001/CHECKSUMS
sudo navishai-reset restore --from /root/navishai-reset-backups/point-001 \
  --confirm-restore DISPLAYED_CHECKSUMS_SHA256
sudo navishai-reset start

# Preview; repeat with its digest only when destruction is intended.
sudo navishai-reset cleanup
sudo navishai-reset cleanup --apply --confirm-destroy DISPLAYED_PLAN_SHA256
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

Restore needs validated installed roots and an env file. It supports same-install
rollback and lost-volume/image/release recovery, not clean-host disaster bootstrap.
Rebuilding an entire lost VPS still needs a separate approved host/bootstrap plan.

## Ownership and startup

The CLI owns `/opt/navishai-reset`, `/etc/navishai-reset`, `/var/lib/navishai-reset`
and the exact `navishai-reset` Compose project. `current` points to an immutable
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

Core command tests pass 15 tests / 138 assertions, recovery tests 10 / 30 and
namespace-policy tests 8 / 155, with no failures, errors or skips. They test command
ordering, both startup guards, literal env parsing, distinct secrets, lock/restore
contracts, writable-root and shared-resource/partial-install cleanup refusal. Bash syntax and
native Ruby style pass. The real namespace-policy and PG recovery proofs pass;
their scope and limits remain in [policy](./VPS_POLICY.md) and
[recovery](./VPS_RECOVERY.md). Combined real CLI proof and full CI remain pending.
Host-side proof builders disable both Docker `iptables` and `ip6tables` manipulation.
Native fixture/unit tests alone cannot certify public ingress, ACME/DNS, SMTP/OIDC,
the owner's firewall or storage, live recovery or customer/model quality.

Owner-specific inputs remain hostname/DNS, access to public 80/443, SMTP, and a
root-controlled Linux/systemd Docker host with the required namespace/firewall tools.
No VPS, live data, provider, paid call, release or deployment has run.
