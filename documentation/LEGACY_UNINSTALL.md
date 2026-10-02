# Remove the old CLI-managed installation

The owner permits deletion of old NavishAI test data before the reset. No backup
is required. This tool does not install the reset or migrate old data.

Copy `bin/uninstall-navishai-old` to the VPS, then preview:

```sh
sudo bash uninstall-navishai-old
```

Read the exact project, source/release, container IDs, network IDs, volume names
and paths. Then copy the displayed plan digest, not the file's checksum:

```sh
sudo bash uninstall-navishai-old --apply --confirm-destroy DISPLAYED_PLAN_DIGEST
```

Repeat any preview options on apply. `--root /path` supports the old installer's
managed-root prefix. If no containers remain, project discovery cannot infer the
name: inspect Docker's exact labels and pass `--project NAME`. Never guess a name.

The tool verifies the historical CLI/current symlinks, source identity, config
labels and root-owned directories. It locks the old installer, checks every
container, volume, network and bind relationship, then binds consent to that plan.
Apply stops/removes only those exact containers, removes the verified networks
and named project volumes, and deletes the old CLI/releases/config/state/backups.
It stops on the first failure; inspect any partial cleanup before another preview.

External volumes and bind paths stay by default. After confirming exclusive
ownership, add `--delete-volume EXACT_NAME` or `--delete-bind EXACT_ABSOLUTE_PATH`
to preview and apply. The resource must belong to a mount of the verified old
project and have no overlap with another container. A path must also be root-owned,
canonical and narrow, with no mounted filesystem beneath it. Docker cannot prove
whether a host process uses an external path: check that before naming it.

Shared mounts/resources, extra `navishai*` systemd units, mounted filesystems,
unexpected layouts/services, changed plans and nonlocal Docker contexts refuse
cleanup. The old CLI created no systemd unit. Resolve uncertain ownership rather
than disabling these guards. Images and packages stay; this tool never prunes,
stops Docker, changes firewall rules, sources `.env`, or executes old installer code.

Layouts were checked against the first CLI release
[`e8dba3a`](https://github.com/glnarayanan/navishai/commit/e8dba3a)
and the final pre-reset installer
[`94180d2`](https://github.com/glnarayanan/navishai/commit/94180d277e624d4b478efd3e3048e0a1c67358d5).
The native fixture tests cover preview, exact destructive targets, changed consent,
stop failure, shared volume/bind/network paths, extra services/mounts and symlink
escape. They use root-owned temporary fixtures and a mock Docker client, never an
existing installation. No command ran on the owner's VPS.

```sh
bash -n bin/uninstall-navishai-old
bundle exec ruby test/ops/legacy_uninstall_test.rb --seed 208
bin/rubocop test/ops/legacy_uninstall_test.rb
```

These are engineering checks, not proof that the owner's unseen host layout matches.
The safe next step is its read-only preview, without posting secret values.
