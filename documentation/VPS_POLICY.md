# VPS application namespace policy

`ops/vps/policy.sh` is a sourceable Bash unit, not an installer or a host
firewall manager. It enforces OUTPUT inside the `app-net` Docker namespace.
The VPS CLI owns startup, systemd persistence, locking, stopping workloads,
Compose, HTTPS, database roles, recovery and uninstall.

## Contract

Run as root with Bash 4.3+, coreutils (`stat`, `sha256sum`, `tail`), host
`nsenter`, `iptables`, `ip6tables` and both restore tools. Use a trusted root
PATH. Both kernel filter families must work, even on an IPv4-only deployment.
This unit adds no gem, package, service or container tool.

The caller sets `VPS_PROJECT=navishai-reset` and supplies two Bash command
functions, `vps_compose` and `vps_docker`. They must select the same scoped,
local Docker daemon and exact production Compose files; do not inherit remote
Docker contexts or an untrusted environment. Tests can select a private socket.
Neither function may log secrets. The policy inspects metadata only, never
container environment values.

`vps_policy_apply` installs a fresh policy or verifies an exact existing one.
`vps_policy_check` only verifies. Both return nonzero on any failure. Neither
starts or stops a workload. A failed check is not a warning: the caller must
stop web/jobs/proxy and refuse further workload startup.

Required topology:

- Exactly one running `app-net` and `postgres` selected by scoped Compose.
- Both containers and both networks have `com.navishai.owner=navishai-reset`
  and exact Compose project/service or network labels.
- `app-net` joins only `navishai-reset_control` and `navishai-reset_edge`,
  runs as `1000:1000`, drops ALL capabilities, adds none, has
  no-new-privileges, no privileged mode and `restart: "no"`.
- PostgreSQL joins only that same internal control bridge, with one current
  IPv4 address, no control IPv6 address and `restart: "no"`. Edge is a
  non-internal bridge. Both network IDs must match Docker's live records.
- Web/jobs share `network_mode: service:app-net`, drop ALL capabilities,
  run as the runtime UID with no-new-privileges and `restart: "no"`.
  These workload settings belong to the caller, not this unit's inspection.
- The holder publishes 3000 only on host loopback. The separate HTTPS proxy
  reaches it over control. Publication and proxy config belong to the caller.

The unit checks holder PID and running state, proves its namespace differs from
both itself and PID 1, then opens a namespace descriptor before calling
`nsenter`. PID reuse cannot change the pinned target. It rechecks all Docker
metadata after the operation. A SHA-256 rule comment binds the policy to current
container IDs/PIDs, namespace inode and both network IDs/addresses. A changed
identity cannot inherit an old green check.

## Ordered rules

An unconditional first OUTPUT jump enters `NAVISHAI_OUTPUT` in each family's
filter table. The chain permits, in order:

1. ESTABLISHED/RELATED packets in conntrack **REPLY** direction. Replies to
   control ingress survive; a private connection opened before policy does not
   gain an outbound exception.
2. Namespace loopback: IPv4 `127.0.0.1` and IPv6 `::1`, only on `lo`.
   Other `127/8` destinations get no broad loopback grant.
3. Docker DNS: IPv4 `127.0.0.11` on `lo`, TCP/UDP with original conntrack
   destination `127.0.0.11:53`, ORIGINAL direction. Docker DNATs port 53 to a
   random resolver port before filter OUTPUT, so a current-port-53 rule alone
   would break DNS. Other resolver ports get no exception.
4. Only the exact current control PostgreSQL IPv4 address, TCP destination 5432.
   This does not permit another control peer or another PostgreSQL port.
5. IPv6 neighbour solicitation/advertisement (types 135/136), not general ICMPv6
   or link-local TCP/UDP.

IPv4 then rejects every private/special-use CIDR in `Operations::EdgePolicy`
and `EvaluationHttp`. IPv6 rejects destinations outside `2000::/3` plus those
modules' special-use global ranges. Remaining public traffic is allowed. The
native test checks CIDR parity with both sources of truth.

This is a destination boundary, not approval to disclose data. All six endpoint
purpose registries, exact workspace/URL checks, human consent, HTTPS/address
pinning and no-retry rules remain in force. See [SECURITY.md](./SECURITY.md).
Docker DNS can resolve external names through Docker's resolver; DNS resolution
is not application permission to connect to a private answer. A malicious root
or Docker administrator can bypass this policy and is outside this boundary.

## Startup, replacement and failure

Hold the caller's root-owned install lock for every mutation. Stop web/jobs/proxy
before changing the holder, PostgreSQL or networks. Then:

1. Create/start only app-net and PostgreSQL, with Docker auto-restart disabled.
2. Run `vps_policy_apply`, then `vps_policy_check`.
3. Only after both succeed, create/start workloads in the checked namespace.

The VPS systemd oneshot must repeat this sequence after reboot or daemon
replacement. Docker must not start workloads on its own before the policy.
Preparation/recovery processes that join this namespace need the same prior
check; never run an arbitrary network-enabled maintenance process first.

The unit uses `--noflush` and adds only its chain and first OUTPUT hook. It never
changes host firewall rules or sysctls, NAT, unrelated chains or INPUT/FORWARD.
It rejects a changed chain, a shadowed/duplicate hook and a partial installed
policy. It does not silently repair or replace them. Stop workloads and recreate
the owned holder; do not fix this by flushing the host or arbitrary namespaces.
If applying the second family fails after the first succeeds, startup still
fails. Recreate the holder before retrying a partial policy.

## Verification and limits

Metadata/rule checks:

```sh
bundle exec ruby test/ops/vps_policy_test.rb
bash -n ops/vps/policy.sh test/support/vps_policy_inspect_fixture.sh
bin/rubocop test/ops/vps_policy_test.rb test/support/vps_policy_{proof,peer}.rb
```

The integration proof is **orb-only**, using disposable assets and no live data,
provider, shared daemon or VPS:

```sh
ruby test/support/vps_policy_proof.rb
```

It builds the existing Rails image from the exact reset base, verifies the
official private Compose download, transfers the pinned PostgreSQL image, and
uses an isolated Docker daemon and network namespace. Synthetic local peers
stand in for public and private destinations; no public request runs from the
workload. The proof checks reachable-before/kernel-denied-after IPv4/IPv6,
exact PostgreSQL/DNS/loopback/replies, pre-policy established denial, tamper
refusal, restart/reapply, cleanup and unchanged shared host rules/sysctls.
Image/Compose downloads and the Rails image build need network access; they do
not authorise provider calls or customer disclosure.

The host-side build daemon disables both `--iptables` and `--ip6tables`, bridge,
IP masquerade and forwarding. Docker 29 has a separate IPv6 firewall switch:
disabling IPv4 alone still writes host IPv6 chains. The first proof attempt
exposed that harness error; cleanup removed only those new proof tables.

On 2 October 2026, the final proof passed and ended with `CLEAN`: all owned
assets removed and shared IPv4/IPv6 rules and checked sysctls unchanged.
Docker 29.8.1, Compose 2.39.4 and iptables/ip6tables 1.8.9 (nf_tables) ran the
proof. Native policy checks passed 8 tests / 155 assertions; with the existing
edge-policy checks, 12 / 228 passed, with no failures, errors or skips. Bash
syntax, Ruby style and diff checks passed. Direct risk review used; named audit
tools and ShellCheck were unavailable. Earlier harness failures are not passes.

This unit does not prove public HTTPS, public useful egress, a real VPS reboot,
systemd ordering, restricted database roles, backups, recovery or uninstall.
Those require joined CLI/topology proofs and an authorised host.
