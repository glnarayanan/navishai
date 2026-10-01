# Non-live operations acceptance

This is local engineering evidence, not a deployment approval. The owner controls
hosting, endpoint approval, credentials and customer data. No host firewall,
existing database, shared Docker daemon, paid endpoint or deployment may enter
these checks. Each command creates random disposable names and accepts no existing
database names. Catchable failures clean its own assets; host loss or SIGKILL can
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
two roles, recreates the same restricted role contract with a generated test secret,
then runs `pg_restore --create --exit-on-error`. It does not use `--no-owner` or
`--no-acl`, restore globals from the shared cluster, or import another role.

Every complete public-table fingerprint, database/schema/relation owner and ACL,
and owner default table/sequence ACL must match. Real password-authenticated runtime
logins read all four databases and test 20 privilege denials. Post-restore
owner-created tables/sequences must allow runtime DML without granting ownership.
The same grant code serves the production `db:grant_runtime` task; production still
uses exactly `navishai_setup` and `navishai`, with separate credentials.

Under restored runtime grants, raw SQL checks immutable definitions/results/labels,
fixed claims and terminal receipts, workspace/corpus foreign keys and append-only
audits. Runtime cannot TRUNCATE audits; the owner-level restored truncate trigger
also refuses it. Duplicate completed delivery cannot send again. Source expiry
hides dependent definitions; runtime purge clears source-backed results, labels and
associations while retaining the content-free deletion audit. No new receipt table,
product record or provider access is added by this proof.

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

## Remaining host gate

An authorized disposable clean public host is not available in this orb. Public
ingress/useful public egress, public TLS/proxy, deployment destination-deny behavior,
SMTP/OIDC delivery and customer-controlled live backup acceptance remain unproved.
A private namespace and simulated public-address peer cannot establish them.
No host, firewall, infrastructure or hosting policy change is authorized here.

The local namespace deny/lifecycle proof and schema-upgrade rehearsal are separate
checks. Record their executed commands and limits here when they pass; do not count
planned code as acceptance.
