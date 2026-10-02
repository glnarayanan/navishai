# Non-live operations acceptance

This is local engineering evidence, not a deployment approval. The owner controls
hosting, endpoint approval, credentials and customer data. These checks never change
the host firewall, shared Docker daemon or an existing application database. No paid
endpoint or deployment runs. Each proof creates random disposable names and accepts
no existing database names. Catchable failures clean its own assets; host loss or SIGKILL can
leave the exact names printed at startup. Never clean by broad name matching.

## Four-database recovery

Run `bin/prove-backup-restore` with the locked Ruby bundle and PostgreSQL 16 tools.
The local socket `/var/run/postgresql` needs peer access for the current Unix user
with create/drop-database and create/drop-role rights. This permission belongs to
the proof administrator, never the deployed runtime role.

The proof creates four unique primary/cache/queue/cable databases and two unique
non-elevated owner/runtime roles. It loads the actual lab SQL structure and the
three checked-in production auxiliary schemas, then seeds only synthetic data.
The primary fixtures include exact source/tenant/case/approval/result/label lineage,
batch and conversation receipts, fixed masking rules and correction history.
The queue retains a serialized analysis job and its ready execution; cache/cable
retain distinct bytes. No native worker runs while the four archives are captured.
This stopped-writer method, not four unrelated live dumps, defines the recovery
point. A live operator must also stop web/jobs and every other writer first.

`pg_dump --format=custom --create` retains owners and ACLs. The proof saves the two
roles' public flags without password hashes, drops only its own four databases and
two roles, recreates the same restricted role contract with distinct test secrets,
then runs `pg_restore --create --exit-on-error`. It does not use `--no-owner` or
`--no-acl`, restore globals from the shared cluster, or import another role.

Every complete public-table fingerprint, database/schema/relation owner and ACL,
and owner default table/sequence ACL must match. Real password-authenticated runtime
logins read all four databases and test 20 privilege denials. The runtime password
must fail authentication as the owner. Inserts into restored cache/queue/cable
tables must advance their saved sequences. Post-restore
owner-created tables/sequences must also allow runtime DML without granting ownership.
The same grant code serves the production `db:grant_runtime` task; production still
uses exactly `navishai_setup` and `navishai`, with separate credentials.

Under restored runtime grants, raw SQL checks immutable definitions/results/labels,
fixed claims and terminal receipts, workspace/corpus foreign keys and append-only
audits. Runtime cannot TRUNCATE audits; the owner-level restored truncate trigger
also refuses it. Duplicate completed delivery cannot send again. Source expiry
hides dependent definitions and refuses new labels; runtime purge clears source-backed
results, labels and associations while retaining the content-free deletion audit.
This proof adds no receipt table, product record or provider access.

Executed on 1 October 2026:

```sh
BUNDLE_FROZEN=true mise exec -- bundle install
bin/prove-backup-restore
```

Locked JSON 2.21.2 installed without changing the lockfile. Recovery printed PASS
for four complete fingerprints/ACLs, recreated restricted roles, runtime grants,
lineage/immutability/no-resend and expiry/purge, then CLEAN for four databases,
two roles and private archives. The first runtime rerun correctly refused TRUNCATE
with `PG::InsufficientPrivilege`; the proof now distinguishes that denial from the
owner-level trigger rather than requiring a weaker grant.

This is logical local recovery, not production recovery certification, backup
encryption/retention, PITR, a PostgreSQL major-version upgrade, arbitrary large-data
timing, an RLS claim or permission to bypass owner-controlled lifecycle policy.
Credentials need separate secret-manager recovery and rotation; the proof does
not export them. Four schema dumps also do not back up `rails_storage`; operators
must capture/restore any customer-owned files under the same stopped-writer policy.

## Application/schema upgrade and rollback

Run `bin/prove-upgrade` with the same local PostgreSQL and Ruby setup. It accepts
no database or checkpoint arguments. It checks that the fixed pre-mask ancestor
[`4d2beab`](https://github.com/glnarayanan/navishai/commit/4d2beab97003622396fce8da6d044652f9de72f6)
belongs to the current history, archives its tracked code, and loads its genuine
SQL schema only into new disposable databases. Old code creates synthetic recorded
fail/pass runs on the same fixed case, an expert held-out label and a completed
local analysis. All four databases and role flags enter the pre-upgrade backup.

With writers stopped, the generated owner role runs current `bin/rails db:migrate`.
The schema dump goes into the private proof directory, never into tracked files.
All old business-row fingerprints must stay exact, projecting out only the two
declared new masking columns and empty scenario `draft_notes`. The proof asserts
those defaults, all six new migration IDs and all 12 new workflow tables empty
before excluding those tables from the old-row comparison. It checks Rails'
environment/schema metadata separately; it does not silently ignore business
changes. Queue/cache/cable rows and ACLs stay exact. Current code then connects
through actual runtime authentication, tests old source/case/approval/label/result
lineage, 13 immutable-table SQL guards, both workspace/corpus FK boundaries, audit
protection, no duplicate execution, new masking, expiry and purge.

Rollback restores the pre-upgrade four archives and restricted roles, not downward
data-destructive migrations. Every pre-upgrade fingerprint and owner/ACL must match.
Fresh old-code runtime execution must pass the same history and lifecycle guards.
No worker or HTTP/model endpoint runs during either schema transition.

Executed on 1 October 2026:

```sh
bin/prove-upgrade
```

The command printed PASS for the real masking migration, unchanged old rows and
auxiliary databases, fresh runtime controls, then four-database backup rollback
and old-code controls. CLEAN removed only its four databases, two roles and private
archive/checkpoint checkout. This rehearses one real additive application migration
on PostgreSQL 16, not a PostgreSQL major upgrade, every older migration path,
zero-downtime rollout, arbitrary customer-data timing or live-host acceptance.
When another schema change lands, review and extend the explicit old-row projection
and new-schema assertions; a prior PASS does not certify a new migration.

## Namespace-scoped edge deny and lifecycle

`bin/apply-compose-egress` uses the installed `iptables`/`ip6tables` tools only in
an explicit private network namespace. It refuses the caller and PID-1 host
namespace, checks the exact Docker `br-<network-id>` interface, and requires
bridge filtering to be enabled already. It never enables a shared sysctl, flushes
an existing table or changes Docker's control network. IPv4 denies match the
application's special-use address boundary. IPv6 permits global destinations only,
with the same special-use denies and only the ICMPv6 neighbor packets needed to
route traffic. A recheck requires exact rules and first-position hooks; an earlier
allow rule fails rather than producing a false PASS.

Rules enter INPUT and FORWARD before Docker's accepts. INPUT also blocks private
edge-to-gateway destinations; FORWARD covers same-edge peers and routed traffic.
Established replies remain allowed. Internal control/database traffic and container
loopback remain separate; this is an edge rule, not a full host perimeter or the
application's per-workspace endpoint registry. Application DNS/address pinning and
human/operator disclosure checks remain required and unchanged.

For an approved customer deployment whose Docker daemon runs in an owned namespace,
create the edge network with web/jobs stopped, apply and verify policy, then perform
owner-run schema preparation/grants and start web/jobs. Do not expose an unprotected
startup window. Verify policy again after daemon/network recreation, before apps
restart. Compose alone does not enforce destination policy or this startup order.

```sh
bin/apply-compose-egress "$OWNED_NETNS" "$EXACT_EDGE_BRIDGE"
```

The script intentionally refuses the normal shared-host Docker namespace. A customer
using that topology must authorize and enforce equivalent controls through their
own host/network policy. This work neither selects a new hosting policy nor grants
authority to change one. A failed/partial policy check must leave workloads stopped.

`bin/prove-compose-runtime` exercises the actual tracked composition in fresh
private daemons/namespaces with unique containers/volumes. Image compilation is
bounded to two CPUs and 1 GiB. Generated destinations exist only inside the private
namespace; it has no public route. Before policy, reachable metadata (169.254),
CGNAT (100.64), benchmark (198.18) and same-edge private peers establish real paths.
After policy, web/jobs must receive kernel rejection, not a timeout. Public-shaped
IPv4 TLS still verifies its generated trust chain and hostname. Test-only IPv6
addresses/routes in the disposable bridge/web namespaces prove reachable ULA and
documentation destinations are then denied while public-shaped IPv6 TLS stays
reachable. IPv4 and IPv6 REJECT counters must increase.

The proof retains the original UID/capability/no-new-privileges, exact production
roles and empty endpoint registries. Native jobs complete the two-family analysis;
cache/queue/cable and control access stay usable. Web/jobs restart without owner
credentials; loopback `/up` must remain HTTP 200, both policy families must recheck,
web/jobs must still reject private IPv4 destinations and a fresh native analysis
must finish without changing the old completed history. Test-only earlier allow
rules in INPUT/FORWARD for both families must fail policy verification, then the
proof removes only those exact rules before continuing.
The host's IPv4/IPv6 firewall snapshots must remain unchanged. Cleanup removes only
the exact daemons, project, namespace mount, images, volumes, secrets and archives.

Executed on 1 October 2026:

```sh
umask 077
bin/prove-compose-runtime
```

The first policy run failed closed because the unprivileged orb user could not stat
PID 1's namespace. The script now reads that identity through `sudo` before changing
private rules. The final run passed IPv4/IPv6 packet denials, shadowed-rule refusal,
TLS/control/ingress and fresh jobs after restart in 276.94 seconds before cleanup.
It printed CLEAN and verified unchanged host firewall snapshots. This remains
simulated local network evidence, not useful public egress, public TLS or live-host
enforcement. The image used tracked application commit
`58682b69f6b362520c6f21971b0d7539db21fb4d` (local, not pushed).
Later changes here affect only proof scripts, tests and operations notes.

## Focused native checks

Executed with Ruby 4.0.6 and PostgreSQL 16 on 1 October 2026:

```sh
mise exec -- ruby test/ops/runtime_database_access_test.rb
mise exec -- ruby test/ops/edge_policy_test.rb
bin/rubocop lib/navishai/runtime_database_access.rb lib/tasks/production_access.rake \
  ops/database_recovery.rb ops/upgrade_fixture.rb ops/edge_policy.rb \
  test/ops/runtime_database_access_test.rb test/ops/edge_policy_test.rb \
  bin/prove-backup-restore bin/prove-upgrade bin/prove-compose-runtime bin/apply-compose-egress
env -i PATH="$PATH" HOME="$HOME" RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 \
  NAVISHAI_APP_HOST=example.invalid \
  DATABASE_URL=postgresql://unused:unused@127.0.0.1:1/navishai_lab_production \
  bin/rails zeitwerk:check
```

Runtime grant tests: 4 tests, 21 assertions, no failures/errors/skips. Edge policy
tests: 4 tests, 73 assertions, no failures/errors/skips. RuboCop: 11 files, no offenses.
`ruby -c` passed on each of those 11 files; `git diff --check` passed. Eager loading
printed `Otherwise, all is good!`; the existing optional image-processing and
non-eager-loaded mailer-preview warnings remain. No dependency was added for them.
The eager-load URL uses an unused port and dummy credentials.

Direct review found and fixed shared proof-role credentials and policy checks that
accepted a deny jump behind an allow rule. The credential regression failed before
the fix; the final password check and four real kernel-priority mutations passed.
Ponytail Audit and CE Code Review tools were unavailable. After cleanup, read-only
catalog checks found zero `navishai_ops_` databases and roles, and the final exact
Compose directory was absent. No broad cleanup ran.

### Mixed Rails test isolation

A follow-up seed-1 run reproduced four Workspace fixture errors: ops teardown
dropped its databases/roles but left their configuration on `ActiveRecord::Base`.
The test now saves the prior pool configuration and restores it in `ensure`, or
removes the proof pool if none existed. Every teardown asserts exact restoration.
That assertion failed on all four ops tests before the fix. The proof helper and
standalone operations scripts did not change in that fix.

A one-off wrapper created fresh names through `Operations::DatabaseRecovery`,
loaded the lab structure, set its generated `DATABASE_URL`, `RAILS_ENV=test` and
`PARALLEL_WORKERS=1` for Rails, and cleaned its assets in `ensure`. These commands
ran inside it:

```sh
bin/rails db:environment:set
bin/rails test test/ops/runtime_database_access_test.rb test/models/workspace_test.rb --seed 1
bin/rails test test/ops/runtime_database_access_test.rb test/models/workspace_test.rb --seed 2
bin/rails test test/ops/runtime_database_access_test.rb test/models/workspace_test.rb --seed 19
```

Each mixed run passed 8 tests and 34 assertions, with no failures/errors/skips.
The initial manual schema load lacked Rails environment metadata; the native
metadata command resolved its preparation error before the final runs. Only
disposable databases received work; no existing test database was reset.
`mise exec -- ruby test/ops/runtime_database_access_test.rb --seed 1` passed 4 tests
and 25 assertions standalone. RuboCop, Ruby syntax and diff checks passed. This
checks mixed fixture execution, not the parent's full integrated-schema suite.

### Local TCP test administrator

The GitHub job supplies PostgreSQL over TCP, not the orb's peer socket. A separate
password-only PostgreSQL 16 instance, with a different administrator name and port
56282, exposed a test gap: ops ignored the declared test connection and used
`/var/run/postgresql`. The new administrator/port regression failed before the fix
with one test, two assertions and one host mismatch. That is a local reproduction,
not attribution of a remote CI failure.

Ops tests now take only host, port, username and password from the prior Rails
test configuration, or its native `DATABASE_URL` parser when no pool exists.
The proof helper accepts only the fixed peer socket or loopback hosts; it still
creates random disposable database/role names and never accepts an existing name.
Default standalone recovery/upgrade scripts still use peer access. Every SQL,
Rails, libpq URL and PostgreSQL tool connection shares the same declared port.
Only PostgreSQL tools receive the administrator password; tool failures redact
all three secrets. Other child processes receive none. Privilege and exact pool
restoration checks remain intact; no test is skipped.

Executed on 2 October 2026 against that fresh private cluster:

```sh
DATABASE_URL="$DISPOSABLE_TCP_TEST_URL" mise exec -- ruby test/ops/runtime_database_access_test.rb --seed 1
env -u DATABASE_URL mise exec -- ruby test/ops/runtime_database_access_test.rb --seed 1
bin/prove-backup-restore
bin/prove-upgrade
```

Both transport runs passed seven tests / 42 assertions, no failures/errors/skips.
They checked real runtime authentication and DML, owner-password refusal, exact
ACL changes, declared administrator/port through Rails/libpq/psql, nonlocal refusal
and secret handling. Recovery and upgrade passed/CLEAN again with current v3
receipts, actual runtime SQL denials, no resend and expiry/purge. The temporary
TCP cluster carries synthetic data only and has no portal or public listener.

## Remaining host gate

An authorized disposable clean public host is not available in this orb. Public
ingress/useful public egress, public TLS/proxy, deployment destination-deny behavior,
SMTP/OIDC delivery and customer-controlled live backup acceptance remain unproved.
A private namespace and simulated public-address peer cannot establish them.
No host, firewall, infrastructure or hosting policy change is authorized here.

The three local proofs close their named engineering gaps, not this host gate.
No screenshot is needed for these nonvisual checks.

## Combined rebuild receipts and runtime checks

The shared synthetic fixture in `ops/current_workflows_proof.rb` now exercises
matching, source-assumption impact and trace-discovery receipts, expert source-review
notes, coupled variants, v2 support observations and the explicit complete-text
processing version. It uses stubbed transport only. Recovery fingerprints these
records before four-database backup and verifies their exact values after restore.
Upgrade first asserts additive defaults and empty new tables, then fresh current
code creates and checks these workflows under actual runtime authentication.
Old-code backup rollback never loads the new helper.

Both proofs now pass all 12 new-table immutable UPDATE guards and trigger-disable
denials, foreign-corpus matching/trace membership, claimed impact-input refusal,
frozen variant-parent and draft-note guards, no completed resend, expiry and
corpus-wide deletion with content-free audits. A first lineage probe hit a duplicate
key before the foreign key; the corrected probe uses a distinct foreign input and
requires `PG::ForeignKeyViolation`, not any rejection. No product guard changed.

Executed against the combined slice-79 schema on 1 October:

```sh
bin/prove-backup-restore
bin/prove-upgrade
DATABASE_URL=postgresql:///navishai_lab_browser72_test PARALLEL_WORKERS=1 \
  bin/rails test test/ops/runtime_database_access_test.rb \
  test/ops/edge_policy_test.rb test/models/workspace_test.rb --seed 1
bin/rubocop
bin/rails zeitwerk:check
```

Both database proofs printed PASS and CLEAN. The mixed native tests passed
12 tests / 107 assertions with no failures, errors or skips. Ruby style passed
371 files; eager loading passed. Brakeman reported zero errors/warnings and the
gem/importmap audits passed. Initial static checks flagged the argument-prefix
expansion and PostgreSQL-specific quoting in proof-only helpers. The fixed
executable now precedes argv expansion and native Rails quoting handles SQL
identifiers/values. No shell command, guard, scope or warning exclusion changed.
Both database proofs and the mixed tests passed again after those changes.

```sh
umask 077
bin/prove-compose-runtime
```

The combined tracked-image run passed in 434.17 seconds before cleanup, using
[`56b3644`](https://github.com/glnarayanan/navishai/commit/56b3644c89ca4243b377fa09ca227722931a39f9).
It checked all six empty disclosure registries and queued synthetic
matching/impact/discovery attempts for the separate native worker. Each interrupted
without a result, before and after web/jobs restart; local two-family analyses
completed. The IPv4/IPv6 kernel denials, four hook-priority mutation refusals,
trusted simulated TLS/control/loopback checks and unchanged host firewall passed.
CLEAN removed the exact private daemons/project/namespace/images/volumes/secrets
and archive. Full combined application CI remains separate from this proof.
