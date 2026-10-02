# Disposable VPS CLI proof

Run only in an orb with disposable storage and passwordless sudo:

```sh
ruby test/support/vps_cli_proof.rb
```

The proof calls the real `bin/navishai-vps` entrypoint. It starts from exact
reset base `6c9fa890127c7cbfac59b810f68ebd9b3bb77603`, copies the current
VPS units into a private source checkout, records their SHA-256 values and
commits that synthetic source. Install and upgrade still build Git archives,
not the working tree. No production file changes in the shared checkout.

## Isolation and substitutions

The host-side builder uses a private socket/data root, VFS, no bridge,
no publication, and both `--iptables=false` and `--ip6tables=false`.
IP masquerade and forwarding stay off. It downloads pinned images and the
checksum-checked official Compose 2.39.4 binary, then builds the real Rails
image through that same Compose classic builder. Both build flags pass through
`sudo env`, and a warm-only Compose override allows host-network build downloads.
The source archive extracts as root and uses the CLI's `a+rX,go-w` modes; file
mode and tar-header differences can invalidate classic COPY cache keys even
when file bytes match. No warm override reaches the runtime configuration.
After stopping this private builder, the proof copies its data root
into another private daemon. This retains both pinned RepoDigest records
and intermediate build cache; Docker save/load would lose them.

The runtime daemon and Docker bridges live in a separate network namespace.
They have no host route or registry proxy. Actual install and upgrade must
accept cached exact pinned images without registry access. Actual Compose
builds reuse the copied cache. The proof never selects a shared Docker daemon.

Only two host interfaces change for the test:

- A PATH-scoped `systemctl` fixture records registration and runs the exact
  generated ExecStart in a separate process. The real startup child must
  acquire the install lock after the installer releases it. On failed startup,
  the fixture dispatches the generated ExecStopPost too. This does not prove
  systemd registration, timer scheduling or a machine reboot.
- A PATH-scoped curl fixture runs real curl inside the runtime daemon's
  namespace and supplies Caddy's generated internal CA during the install gate.
  The real CLI resolves HTTPS to namespace loopback and checks CA and hostname
  before recording READY. No request uses `-k` or skips certificate checks.

The only production source adjustment is `tls internal` in the synthetic
Caddyfile. The fixture restores executable mode on the private CLI copy because
thread file transfer carries bytes, not mode; the parent must retain mode 100755
in Git. Real Caddy terminates HTTPS and forwards through control to the
holder. This is not public DNS, ACME issuance or public useful-egress evidence.
The Docker PATH wrapper selects the private socket and checks writer state
around actual maintenance commands; it does not replace Docker responses.
A tar forwarder preserves actual output bytes and exit status while recording
archive headers, not payloads. Failed backups report the last complete listing
and recent Docker command statuses. No new production dependency or service
enters the repository.

## Checks

The proof exercises actual install, startup, check, status, stop, upgrade,
backup and consent-bound restore. It checks:

- Installer-to-startup lock handoff, exact shared runtime namespace,
  dropped capabilities, runtime UID and disabled Docker auto-restart.
- Unchanged holder/PostgreSQL IDs and Running=true across stopped workload
  creation and the actual pre-start inspections; web/jobs stay Running=false
  until explicit start. Docker responses remain real.
- Restricted preparation/runtime roles and ownership of all four databases
  and schemas; native runtime privilege denials and immutable audit writes.
- Separate native jobs finishing local analysis and refusing optional
  matching, impact and trace disclosure under empty purpose registries.
- Actual internal-CA Caddy HTTPS, loopback readiness and control ingress.
- Shadowed IPv6 OUTPUT failing check and stopping writers; explicit start
  replacing that namespace before applying both families again.
- Holder/PostgreSQL replacement with stopped writers; synthetic IPv4/IPv6
  peers reachable before policy and denied afterwards from actual web/jobs,
  with positive kernel REJECT counters and public echoes still working.
- Backup/restore of all four databases, exact checkpoint rows, sequences,
  object/schema owners, ACLs and default ACLs, private env and Rails storage.
- A successful source upgrade and a real failed candidate migration followed
  by full rollback. The failure fixture commits changed rows and sequence state
  before raising, so a code-only rollback cannot pass. Restore and rollback
  leave writers stopped until start.
- No live writers before/after preparation/dump/restore/storage commands and
  no Docker workload-start event inside those audited windows.
- No Docker auto-start after actual daemon restart, then explicit reapply.
- Removal of the private daemons, containers, volumes, images, namespace,
  source and managed host tree, with host IPv4/IPv6 firewall and checked
  sysctl values unchanged.

Every run cleans up its own disposable assets, including on failure. A failed
run is not green evidence. Syntax/style checks alone do not establish these
runtime claims. The proof logs source identities so later source changes
cannot inherit an earlier pass.

## Limits

No VPS, live database, customer data, provider call, paid service, mail delivery
or OIDC provider runs. Production uninstall/cleanup belongs to the parent
integration unit, not this proof. Backups remain disposable and unencrypted;
this proves neither backup storage policy nor PITR. Root and Docker admins
can bypass namespace policy and SQL guards. Shared-host reboot and public
network/TLS acceptance need a separately authorised host.

## Run evidence

Ruby syntax, four embedded Ruby blocks, four embedded Bash blocks and native
RuboCop pass. On 2 October 2026, the full joined CLI proof returned exit 0 with
CLI SHA-256
`76ac2119bf2912d346a77de071901b26dfc9276593f02081d4bfac8ec43b33aa`
and recovery SHA-256
`e793c033171998d5affb2e5fac054b3188c75e030ef7a714c017d8af524d5202`.
The executed proof script SHA-256 is
`11331ea0d6ccdd72a401c5b7081c0610e6cb7759f8a2edab46d0443c25e44736`.
The log records all seven production file hashes and the synthetic release.

The completed run passed all checks above, including:

- Actual install, startup-child lock handoff, trusted internal-CA HTTPS,
  restricted roles across four databases, native jobs and privilege denials.
- Holder/PostgreSQL replacement, fail-closed shadowed policy checks and
  kernel IPv4/IPv6 rejection from web/jobs after reachable-before probes.
- CHECKSUMS-consented restore with exact checkpoint rows, 47/false sequence
  states, object/schema owners, ACL/default ACL, private env and Rails storage.
- A successful upgrade and a failed migration that committed changed rows
  and sequence state 97/true before raising. Full rollback restored the prior
  source/image/config/four-DB point and left writers stopped until explicit start.
- Four-DB runtime DDL denial and fixed native history after restore, rollback
  and daemon restart, without resending refused work.
- 14 actual pre-start inspections and 142 maintenance windows checked before
  the final daemon restart. Holder/PostgreSQL IDs stayed fixed and running while
  web/jobs stayed stopped until explicit start. No workload-start event fell
  inside those windows. The final startup used the same state-checking wrappers.
- An actual daemon restart with no automatic workload startup, then explicit
  namespace-policy reapplication and checks.
- Complete disposal of private assets and unchanged host IPv4/IPv6 firewall
  and all four checked sysctls.

Before the joined run, a real-image probe archived both Caddy named volumes
without rewriting metadata. Each root-owned `./caddy/` directory retained mode
1777. Both `root` guards returned 1 and both `caddy` guards returned 0. The probe
also removed its assets and matched host firewall/sysctl snapshots. These checks
do not remove the host, public-network or TLS limits stated above.

The proof has caught these boundary failures:

- Root Git-archive extraction retained file mode 0664 and directory mode 0775.
  Unprivileged warm extraction produced 0644, so identical Gemfile bytes missed
  the COPY cache. Root extraction fixed that fixture mismatch. The parent also
  reproduced a product defect: recovery rejected those group-writable release
  modes. Its CLI now strips group/other write with `a+rX,go-w`; the proof's warm
  source follows that rule too.
- Compose 2.39.4 `pull --policy missing` still called the registry despite
  successful inspect of both exact cached digest references. Its
  [cache predicate](https://github.com/docker/compose/blob/v2.39.4/pkg/compose/pull.go#L157-L168)
  requires a tagged reference, but
  [reference parsing](https://github.com/distribution/reference/blob/v0.6.0/normalize.go#L88-L120)
  strips the tag from `name:tag@digest`. Cache metadata alone cannot fix that
  command. The parent now inspects exact pinned references and pulls only when
  Docker reports a missing image. Actual preparation/startup uses `--pull never`.
  The completed run verified the cached path without changing pins or Docker
  responses or adding runtime egress.
- Compose 2.39.4 rejected `create --no-deps` before workload creation. The parent
  now uses `up --no-start --pull never --no-build --no-deps --force-recreate`.
  Actual pre-start inspections verified unchanged running holder/PostgreSQL
  IDs and stopped web/jobs before explicit start.
- Pinned Caddy retains root-owned sticky, world-writable `caddy` directories in
  both named volumes. Backup failed at the generic root-archive validator after
  real Docker dumps and tar listings succeeded. The parent added a `caddy` kind
  that accepts only the exact root-owned, root-level directory mode 1777.
  Other members retain the root rules; generic root/storage/image checks did
  not change. The real-image probe and joined restore passed without changing
  archive permissions or bypassing the validator.

Every completed failed run removed its disposable assets and matched the
before/after host IPv4/IPv6 firewall and checked sysctls. No failed run counts
as a full joined-proof pass.
