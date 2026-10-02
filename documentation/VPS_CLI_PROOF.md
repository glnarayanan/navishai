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
No new production dependency or service enters the repository.

## Checks

The proof exercises actual install, startup, check, status, stop, upgrade,
backup and consent-bound restore. It checks:

- Installer-to-startup lock handoff, exact shared runtime namespace,
  dropped capabilities, runtime UID and disabled Docker auto-restart.
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
  by full rollback; restore and rollback leave writers stopped until start.
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

## Run evidence and open checks

Ruby syntax and native RuboCop pass. The full CLI proof has not passed yet.
The run against CLI SHA-256
`a0215deaf86f3e04eb6e6d2a87d2675c3b611114f826018c95725f4e44f26f0b`
and recovery SHA-256
`56dbe2c80f382dff280da9dab407a7759fc63a5c7b4fa8d7ef02c6dcf0c1d275`
confirmed valid normalized Compose and cached real install builds, then stopped
at pinned image pulls. Startup and recovery checks remain unproved.

Two findings matter for the final source:

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
  command. The parent must settle the pinned-image availability contract;
  the proof will not change configured pins, mock a pull or add runtime egress.

Every completed failed run removed its disposable assets and matched the
before/after host IPv4/IPv6 firewall and checked sysctls. None counts as a
full install, HTTPS, upgrade or recovery pass.
