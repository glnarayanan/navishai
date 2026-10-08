# Disposable VPS CLI proof

Run only in an orb with disposable storage and passwordless sudo:

```sh
ruby test/support/vps_cli_proof.rb
```

The proof calls the real `bin/navishai-vps` entrypoint. It starts from exact
reset base `6c9fa890127c7cbfac59b810f68ebd9b3bb77603`, copies the current
VPS units into a private source checkout, records their SHA-256 values and
commits that synthetic source. The ingress regression first uses the shipped
CLI/override from [`cc443cf`](https://github.com/glnarayanan/navishai/commit/cc443cf09dc8be9d4ea1239b78ff7c642ce0c0ae),
then upgrades to the current files. Both source identities enter the log.
Install and upgrade still build Git archives,
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
Synthetic public IPv4 addresses live on private dummy interfaces with a matching
default route; tailnet IPv4/IPv6 addresses live on private loopback. Neither
namespace has a host route. The actual CLI reads those native interfaces/routes,
not an `ip` mock or a supplied production override. Real TCP
listeners hold both tailnet addresses on 443 throughout install, upgrade, restore
and daemon restart. They model the proven bind conflict, not Tailscale access,
Serve/Funnel configuration or a real Tailscale daemon.

The proof substitutes these external interfaces:

- A PATH-scoped `systemctl` fixture records registration and runs the exact
  generated ExecStart in a separate process. The real startup child must
  acquire the install lock after the installer releases it. On failed startup,
  the fixture dispatches the generated ExecStopPost too. This does not prove
  systemd registration, timer scheduling or a machine reboot.
- A PATH-scoped curl fixture runs real curl inside the runtime daemon's
  namespace and supplies Caddy's generated internal CA during the install gate.
  The real CLI resolves HTTPS to namespace loopback and checks CA and hostname
  before recording READY. No request uses `-k` or skips certificate checks.
- A PATH-scoped `getent` fixture uses real NSS under a private mount namespace
  with a synthetic hosts entry. It changes neither host DNS nor `/etc/hosts`.
  This checks the native resolution gate but does not prove public DNS.

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

The proof exercises actual install, guided resume, startup, check, status, stop,
upgrade, backup, consent-bound restore and clean-destination recovery. It checks:

- The shipped wildcard proxy fails with the exact `0.0.0.0:443` bind error
  after web/jobs start; failure handlers stop them. The new source CLI upgrades
  that partial install through full backup before changing private ingress
  config. Four-DB checkpoint rows, sequence state and owners stay fixed.
- Public IPv4 80/443 plus loopback 443 without wildcard or tailnet bindings;
  both tailnet listeners stay reachable and trusted loopback HTTPS still passes.
- Desired `auto` with no discovered IP in config; automatic partial-install
  upgrade needs no address input. Protected guided answers create the native
  chosen-password Owner through real Compose stdin and record one bootstrap audit.
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
- A second empty Docker daemon/root/network with a different public address
  and interface receives the complete consented source backup. Exact catalogs,
  secrets and history match; local container identities differ. Recovery starts
  no writers. A synthetic registration failure after real restore exercises
  guarded `recover --resume` rather than adoption, deletion or reinstall.
- Changing the destination address makes `check` stop stale writers. Automatic
  gated startup recreates bindings without config edits; destination daemon
  restart keeps the new binding, roles and fixed history.
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

The separate fast proof uses the real normalized Compose port definitions and
kernel TCP binds in a disposable namespace:

```sh
ruby test/support/vps_ingress_proof.rb /path/to/checksum-verified-compose-2.39.4
```

It reproduced wildcard `EADDRINUSE` with the shipped override, then passed with
the fixed public/loopback bindings while both tailnet listeners stayed reachable.
It also calls the actual ingress preflight against those native listeners, first
free and then occupied. It uses no Docker daemon or host-network mutation and
does not certify Docker publication, Caddy TLS or the owner's VPS by itself.

### Automatic ingress, guided setup and portable recovery

The recorded joined proof returned exit 0 and `CLEAN`. All 11 production hashes
matched its frozen source. The later Owner-resume fix changes CLI, setup and
bootstrap handling; it cannot inherit this earlier run. Key SHA-256 values are:

| File | SHA-256 |
| --- | --- |
| `ops/vps/cli.sh` | `6c1fd88ce1f4cd783240618b0988e3f4f6431ee906f196245731e75ecdcf5afd` |
| `ops/vps/ingress.sh` | `23c0a4cc43848c18343e0787e513cc3a1f99dec408b259e67239d704ac925a69` |
| `ops/vps/setup.sh` | `4c31b95f999d8b0bcae2bc03efaddedc209273e31370a555f9c838dacc6e7bb0` |
| `ops/vps/destination.sh` | `a8964aaab502afbf9c8f31875e61262d8b20cb8fa52726937775e7293d67339f` |
| `ops/vps/recovery.sh` | `988ac42cba9a66179fcb9497d46b15ac6033a5422ed6052d84c2fe57c6096c98` |
| Executed proof | `2cb59ebd9ea29a997bd42e285b428f8633a5ada7b89e74d18502a289fe7cef74` |
| Redacted log | `4c0e7a598780af100a3b7494ef64aeb39a5b797bfe35ec4411fda265aaabd748` |

It passed every check above, including the real wildcard failure and backed-up
automatic partial-install upgrade with both tailnet listeners preserved. Guided
resume created the chosen Owner through stdin-only `exec -T` in the running web
service, with one installation marker and one attributable bootstrap audit.
The four-DB/env/storage restore and committed-mutation failed-upgrade rollback
passed. Before the final source daemon restart, 18 actual pre-start inspections
and 175 maintenance windows found stable guarded dependencies, stopped workloads
and no workload-start event inside maintenance.

An empty second daemon/root/network received the source backup on a different
public address/interface without a supplied IP. Wrong consent failed before
bootstrap; an injected registration failure left writers stopped and a guarded
resume succeeded. Exact data, secrets, roles and history matched with new local
identities. A later address change made `check` stop stale writers; gated startup
and daemon restart used the new address without config edits. Both tailnet
listeners remained reachable. Cleanup removed all private assets and matched host
IPv4/IPv6 firewall and all four sysctls.

Four embedded Ruby and five embedded Bash syntax checks pass. Sequential native
CI passes 718 Rails tests / 11,424 assertions (seed 47436) and 71 browser tests /
3,562 assertions (seed 53985). It finished in 24m20.20s. Final operations after the
last setup fixes pass 85 / 1,011 (seed 47436); all 388 Ruby files pass native style.
The broad CI run began before those setup refinements; final operations and this
frozen proof rechecked the changed source afterwards. No check was weakened.

Earlier current-source attempts caught a one-off Owner container launched beside
live writers, then a fixture storage call missing its derived Compose address.
Owner setup now uses the running runtime service; every stopped-maintenance guard
remains. The fixture's shared Compose vector now carries the actual inspected
binding for all three direct calls. Those failed runs cleaned their assets and
do not count as green evidence. No real Tailscale, public ACME/DNS, SMTP delivery,
systemd registration/reboot, VPS or customer acceptance follows from this run.

### Earlier joined proof

The following result predates the ingress extension and records only its earlier
scope; it cannot certify changed source.

Ruby syntax, four embedded Ruby blocks, four embedded Bash blocks and native
RuboCop pass. On 2 October 2026, the full joined CLI proof returned exit 0 with
CLI SHA-256
`76ac2119bf2912d346a77de071901b26dfc9276593f02081d4bfac8ec43b33aa`
and recovery SHA-256
`e793c033171998d5affb2e5fac054b3188c75e030ef7a714c017d8af524d5202`.
The executed proof script SHA-256 is
`11331ea0d6ccdd72a401c5b7081c0610e6cb7759f8a2edab46d0443c25e44736`.
The log records all seven production file hashes and the synthetic release.

That completed run passed the pre-ingress checks, including:

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

### Owner-resume follow-up

The expanded harness expires only the disposable installation's protected token.
Bare guided resume must then refuse with zero users, organisations, installation
markers or bootstrap audits. Guarded renewal must leave writers stopped; another
bare resume must create one Owner/audit and authenticate the chosen password.
No source/commit argument, password argument or immutable release edit is used.

This run freezes the following changed sources; its complete result and log hash
belong in the follow-up PR, separate from the earlier pass above:

| File | SHA-256 |
| --- | --- |
| `ops/vps/cli.sh` | `d418af46c86b52af5bd280fc110a3605df2ffa1b91ad0d3a7850494c1fc80fb6` |
| `ops/vps/setup.sh` | `8ecbccca309b7993bc6c7607f9d864500a92f1b47065d63d4bd8862460719462` |
| `ops/vps/bootstrap_owner.rb` | `c9991e76167866bbeb310168242d79e96a19c4d59053cbd2c82ce3a16c78f050` |
| Executed proof | `fca72c6393935bc7f4ca7b6f4cb89eb75aa22ef131542f86db4cb6ba0348e61d` |

The proof keeps its exact historical application base and current CLI sources.
Application/schema code matches the current branch; Gemfile/lock differ after
the owner's dependency update. Native tests and exact-head CI test Rails 8.1.4
separately. Internal CA, synthetic systemctl/NSS and all other limits above remain.
An expired-token fixture cannot prove the cause of the owner's earlier generic
bootstrap refusal. No agent runs on the owner VPS.
