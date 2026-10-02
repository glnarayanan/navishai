# Evaluation-lab security evidence and limits

Retained controls: local verification/password reset, revocable expiring sessions,
invitation role bounds, first Owner, generic OIDC state/nonce/PKCE and signed-token
checks, protected short-lived break-glass recovery, per-workspace membership
authorization, serialized last-Owner protection, CSP/nonces, security headers,
production host/HTTPS enforcement, rate limits and sensitive log filters.

Workspace reads start from the signed-in user's memberships. Organisation ownership
grants no access to sibling workspaces. Foreign keys, uniqueness and role/status
checks remain in PostgreSQL. These are application authorization and database
constraints, **not PostgreSQL RLS**. Last-Owner protection is a Ruby callback using
a transaction advisory lock; raw SQL can bypass it. Do not grant application users
direct database access.

Audit actions/metadata are allowlisted with scalar/type/size and sensitive-key
validation. Subject workspace mismatches are rejected. Persisted events are Ruby
read-only and PostgreSQL rejects update/delete/truncate. No expiry exception,
notification fanout or old-domain audit vocabulary remains. Tests exercise model
and direct-SQL failures. Database administrators can still disable triggers.

Corpus, sources, snapshots and items use composite workspace/corpus foreign keys.
Intake rechecks a locked membership before committing; viewers cannot write.
Snapshots and items reject updates in Ruby and SQL. HTML remains escaped evidence,
never browser instructions. Bounded UTF-8/JSON parsing and atomic inserts reject
malformed batches. Request logs filter uploaded data and company-content fields.

Email masking covers record text/context and replaces email record IDs with
digests. It does not detect all PII or secrets. Source names and input digests are
still retained; files are not. Expiry hides content at read time and a native hourly
job deletes source snapshots/items. Explicit source deletion needs a managing role
and typed confirmation; it keeps only a non-content audit event. Backups have a
separate operator-controlled retention policy.

There is no source export, evaluation execution or external disclosure yet.
Scenario versions, exact-source evidence and expert decisions are immutable
in Ruby and SQL, with composite workspace/corpus relationships. Current-version
pointers cannot refer to another scenario. All writes recheck a locked membership;
version tokens block stale edits/reviews. Variants retain fixed parent versions and
cannot inherit approval. Source expiry hides their content at read time, and purge
also deletes all corpus scenarios through analysis relationships. Request logs
filter scenario text, decisions, excerpts and mutations. No target receives any data.

Compiled cases/check bindings and grader versions reject updates in Ruby and SQL.
Composite relationships bind evidence and approval to the exact scenario version
and keep graders within the corpus/workspace. Compilation checks full coverage,
current approval and source lifetime under the corpus and membership locks. Suite
admission rechecks these facts rather than trusting cached records. Grader edits
need a current-version token. Request logs filter grader forms and definitions.
Source purge removes compiled cases and all corpus graders; expiry hides grader
text and case inputs before purge. Suite names survive without sensitive cases.

Calibration samples bind an exact output to a compiled check and the set's grader
version through composite foreign keys. Sets, samples, predictions and human labels
reject updates in Ruby and SQL. Writes lock the membership and corpus; labels use
stale-write tokens and cannot overwrite another expert. First-label UI hides machine
and other expert decisions; this is not a security or double-blind boundary. Viewers
can read but cannot label/upload. Expiry blocks reads/writes, purge deletes retained
output and rationale copies, and parameter logs filter both. No external judge runs.

Analysis inputs and cluster members have workspace/corpus foreign keys and
immutable updates. Jobs recheck the requester's membership. Source deletion also
clears corpus-wide analyses/taxonomy revisions; expired inputs block analysis reads
and edits before the hourly purge. Later derivatives must join this policy. OIDC provider and
SMTP tests use local stubs; no live identity provider or mail delivery was verified.
Direct risk-based review replaces unavailable Ponytail Audit and CE Code Review.
