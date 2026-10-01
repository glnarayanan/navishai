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

Corpus search binds escaped literal phrases and scopes source/record links to the
same corpus and retained snapshots. Viewers may search without writes or jobs.
Queries are capped at 200 characters and filtered from Rails parameter/path logs.
The no-referrer policy prevents outbound referrers, not browser URL/history storage.
Do not put secrets in a search phrase.

Email masking covers record text/context and replaces email record IDs with
digests. It does not detect all PII or secrets. Source names and input digests are
still retained; files are not. Expiry hides content at read time and a native hourly
job deletes source snapshots/items. Explicit source deletion needs a managing role
and typed confirmation; it keeps only a non-content audit event. Backups have a
separate operator-controlled retention policy.

There is no source export. External evaluation disclosure requires operator and
expert approval; it is off by default.
Scenario versions, exact-source evidence and expert decisions are immutable
in Ruby and SQL, with composite workspace/corpus relationships. Current-version
pointers cannot refer to another scenario. All writes recheck a locked membership;
version tokens block stale edits/reviews. Variants retain fixed parent versions and
cannot inherit approval. Source expiry hides their content at read time, and purge
also deletes all corpus scenarios through analysis relationships. Request logs
filter scenario text, decisions, excerpts and mutations. Local scripted targets
receive only approved visible context and permitted knowledge, not hidden facts
or expectation evidence. Experts must keep answers out of the starting context.

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
output and rationale copies, and parameter logs filter both.

Calibration review filters are allowlisted read-only states within the selected
cohort. They change no labels, predictions, audit records or jobs, and leave report
counts unchanged. Before a writer's first label, row state/order does not reveal
another expert's decision or the prediction. This reduces anchoring, not access to
aggregate reports. Viewers have no review controls; existing source/access gates apply.

Configured judges need exact workspace/URL operator approval and separate human
disclosure consent. Fixed model/settings/rubric/threshold versions never change
prior cases or labels. Suite consent binds its displayed case list, rejecting stale
membership before queueing. Calibration attempts bind exact samples and request
UUIDs with composite workspace/corpus keys and immutable SQL definitions. Jobs
claim once, release locks before network waits, then recheck access/evidence before
retaining predictions. Stopping or deleting cannot recall sent requests. No automatic
retry occurs. Hidden facts, labels and the full corpus never enter the judge body.
Quoted evidence must exist in the fixed inputs, but no syntax check proves a sound
judgment or prevents model injection. Invalid responses are errors, low confidence
abstains, and usage/cost remain endpoint reports. The shared HTTPS transport uses
the target controls below. No live model or customer endpoint has run here.

Scripted target definitions cannot execute code or external requests. Managing
roles version them with stale-write tokens; writers start bounded runs. Composite
keys bind run items/results to their exact corpus and case. SQL prevents run
definition rebinding; target versions, inputs, results and regression admissions
reject updates in Ruby and SQL. Jobs claim once and recheck locked access, approval
and evidence per case. An unknown outcome never retries automatically. Result
pages escape content; regression admission needs a reported failure and human
reason, not an execution error. Source purge clears corpus targets/runs and their
derived copies; expiry hides them and suite history before purge. These guarantees
do not prove target quality, calibration accuracy or attested tool execution.

HTTP targets require exact per-workspace operator endpoint approval and deliberate
expert confirmation on each run. A case-list digest binds that confirmation to
the reviewed suite, even without configured judges. Changed membership or a
missing token blocks queueing and requires fresh review. Optional bearer tokens
stay in the operator environment; target JSON rejects credentials/extra fields and logs filter forms.
Only fixed visible context/knowledge enter support-target-v1; hidden expectations
stay local. HTTPS port 443, peer/hostname verification, all-answer public-IP checks,
address pinning, no proxy/redirect/retry, a DNS-inclusive 30-second deadline and
bounded uncompressed UTF-8 JSON limit the network surface. Operator egress rules
must also deny private destinations. Internal targets are not supported.

Calls hold no corpus/membership locks. Access, approval and retention are checked
before dispatch and before storing output. A concurrent change stops local
retention/later cases; it cannot recall an in-flight request. Each fixed item has
one request UUID and the endpoint owns deduplication. Errors may leave the remote
outcome unknown; automatic retry stays forbidden. Local purge cannot delete remote
copies. Test-only local TLS routing proves certificate/hostname validation and
streaming without relaxing the production address checks. No real provider ran.

Analysis inputs and cluster members have workspace/corpus foreign keys and
immutable updates. Jobs recheck the requester's membership. Source deletion also
clears corpus-wide analyses/taxonomy revisions; expired inputs block analysis reads
and edits before the hourly purge. Later derivatives must join this policy. OIDC provider and
SMTP tests use local stubs; no live identity provider or mail delivery was verified.
Direct risk-based review replaces unavailable Ponytail Audit and CE Code Review.
