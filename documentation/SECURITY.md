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

Production separates PostgreSQL preparation from Rails runtime. The fresh Compose
volume creates `navishai_setup` for preparation and `navishai` for web/jobs, with
distinct passwords. Preparation owns all four schemas and grants runtime DML and
sequence/schema usage. Runtime has no database/role creation, replication, RLS
bypass, schema ownership or trigger-disable rights. Startup never migrates. The
disposable pinned-image proof checks six privilege denials and audit immutability;
it is not production network, operator-role or upgrade acceptance. Do not reuse an
older volume whose app role owned tables or was a superuser.

Corpus, sources, snapshots and items use composite workspace/corpus foreign keys.
Intake rechecks a locked membership before committing; viewers cannot write.
Snapshots and items reject updates in Ruby and SQL. HTML remains escaped evidence,
never browser instructions. Bounded UTF-8/JSON parsing and atomic inserts reject
malformed batches. Request logs filter uploaded data and company-content fields.

Explicit conversation JSONL uses bounded tempfile lines and two passes, not a
whole-file string. Limits: 60 MiB wire, 100,000 records, 1 MiB per line and 256 MiB
of encoded normalized fields after masking; the existing 64-MiB request limit and
per-record limits remain. Check IDs and masking collisions across the whole file.
Changed second-pass bytes/counts and late invalid records roll back every batch,
source retention and audit. New processing has a distinct version; retained
conversation kind, tenant checks, immutable provenance and disclosure gates stay
unchanged. Syntax errors never echo parser source text. The form retains chosen
format/mode, not private rules or the uploaded file. No provider, job, label or
approval runs automatically. These are bounds, not a proof of PII removal.

Corpus search binds escaped literal phrases and scopes source/record links to the
same corpus and retained snapshots. Viewers may search without writes or jobs.
Queries are capped at 200 characters and filtered from Rails parameter/path and
SQL debug bind logs. A typed, named search bind makes the existing private-field
filter apply; anonymous binds had exposed phrases at DEBUG despite safe SQL.
Active Record uses the same configured field filters as request logging, including
source names, external record IDs, corpus content/context, titles, requirements, follow-up plans, mutations, labels,
signals, model input/results, target input and check decisions. Native DEBUG writes
and typed PostgreSQL-bind tests retain exact stored content while hiding it from
Rails logs. Native intake and record lookup also check private identity binds.
A real taxonomy request checks filtered parameter logging, including
private fields the action ignores. These controls do not filter every SQL expression or
PostgreSQL/proxy/operator log; those need separate restricted access and retention.
The no-referrer policy prevents outbound referrers, not browser URL/history storage.
Do not put secrets in a search phrase.

Corpus, source-impact and shared record pagination force local paths. Query values
remain query data, never routing options such as host or protocol. Fixed fragments,
filters, snapshot selection and independent page positions remain intact. Crafted
queries and actual next/previous navigation are tested without relaxing CSP.

Corpus pages disable Turbo cached previews: a fresh navigation cannot replace
a phrase entered into a cached form. A controlled pending-response browser test
reproduced the loss before this guard; search still submits through the native form.

Email masking covers record text/context and replaces email record IDs with
digests. It does not detect all PII or secrets. Source names and input digests are
still retained; files are not. Expiry hides content at read time and a native hourly
job deletes source snapshots/items. Explicit source deletion needs a managing role
and typed confirmation; it keeps only a non-content audit event. Backups have a
separate operator-controlled retention policy.

Masking rejects key and record-ID collisions before persistence or snapshot reuse,
including nested trace facts/outputs. Repair errors contain no source keys. Intake
does not drop values, switch to original text or repair retained history. Snapshot
reuse binds the processing version and masking fingerprint through a database
unique index; changed processing/rules cannot silently return older artifacts.

Exact-text mode masks only the author's listed case-sensitive literals. It is
separate from email masking, not full PII detection or a customer disclosure policy.
Rules are bounded, escaped literals, never user-executed regexes. Snapshots keep
only the sorted unique list's SHA-256 fingerprint/count; the raw list stays outside
retained definitions, audit, flash and filtered request logs. The author must keep
it privately for reprocessing. SQL rejects inconsistent mode/count/fingerprint
and updates. Trace schemas still revalidate after masking. Source names and older
snapshots stay unchanged; selected patterns may also occur in that metadata/history.
Hashes are not anonymity guarantees. New masks cannot approve or recall disclosure.

Managers/Admins/Owners may download one exact retained snapshot by POST with typed
source-name confirmation. Membership, source expiry and snapshot scope are checked
under the corpus lock. Complete normalized JSON is bounded to 2000 records / 10 MiB;
oversized snapshots are refused, never sampled. A SQL byte lower bound counts
encoded record strings and quoted context fragments before source objects load.
It catches oversized masked strings without mistaking PostgreSQL's JSON spacing
or number formatting for exported bytes. The final complete JSON check still
enforces the exact limit; this preflight is not an exact encoded-size calculation.
Attachments use ID-only filenames,
JSON/nosniff and no-store headers. A content-free snapshot audit records preparation,
not client receipt. Copies retain the snapshot's masking limits and fall outside
local purge; the recipient owns their storage/deletion. No raw files are restored
and no provider receives the download. External evaluation disclosure still needs
operator and expert approval; it is off by default.
Scenario versions, exact-source evidence and expert decisions are immutable
in Ruby and SQL, with composite workspace/corpus relationships. Current-version
pointers cannot refer to another scenario. All writes recheck a locked membership;
version tokens block stale edits/reviews. Variants retain fixed parent versions and
cannot inherit approval. Source expiry hides their content at read time, and purge
also deletes all corpus scenarios through analysis relationships. Request logs
filter scenario text, decisions, excerpts and mutations. Local scripted targets
receive only approved visible context and permitted knowledge, not hidden facts
or expectation evidence. Experts must keep answers out of the starting context.

Local failure matching counts versions, then reads only byte lengths and scoped
link/review metadata before its 10-MiB searched-text check. Source-link rows omit
content/context. Matching versions omit hidden facts, requirements and selection
reasons; ignored knowledge/trace excerpt text does not load. All evidence IDs and
source lifetime/current-document checks remain, including fresh decision checks
on these projections. Full artifact views and deliberate permitted-knowledge
inspection use separate reads. These controls preserve rank and stored data; they
do not prove semantic retrieval quality or cap every metadata allocation.

Compiled cases/check bindings and grader versions reject updates in Ruby and SQL.
Composite relationships bind evidence and approval to the exact scenario version
and keep graders within the corpus/workspace. Compilation checks full coverage,
current approval and source lifetime under the corpus and membership locks. Suite
admission rechecks these facts rather than trusting cached records. Grader edits
need a current-version token. Request logs filter grader forms and definitions.
Source purge removes compiled cases and all corpus graders; expiry hides grader
text and case inputs before purge. Suite names survive without sensitive cases.

Calibration samples bind an exact output to a compiled case/check and the set's
grader version through composite foreign keys. Optional saved-result provenance
must name that same case/corpus/workspace. Intake copies the scoped retained output,
not supplied JSON or its judgments, and requires an explicit cohort. Duplicate
manual/different-result provenance cannot be overwritten. Sets, samples, predictions
and human labels reject updates in Ruby and SQL. Writes lock the membership and corpus; labels use
stale-write tokens and cannot overwrite another expert. First-label UI hides machine
and other expert decisions, including result/run links; this is not a security or
double-blind boundary. Viewers can read but cannot label/upload. Expiry blocks reads/writes, purge deletes retained
output and rationale copies, and parameter logs filter both.

Calibration review filters are allowlisted read-only states within the selected
cohort. They change no labels, predictions, audit records or jobs, and leave report
counts unchanged. Before a writer's first label, row state/order does not reveal
another expert's decision or the prediction. This reduces anchoring, not access to
aggregate reports. Viewers have no review controls; existing source/access gates apply.

Model scenario proposals require their own exact workspace/URL operator registry
and version-specific human disclosure confirmation. Evaluation/judge permission
does not grant source-processing authority. Configuration rejects credentials and
unknown fields. Only bounded fixed context/excerpts enter the existing guarded
transport; hidden facts, expectations, labels and unrelated records stay local.
Each proposed requirement needs an exact disclosed quote, not an invented or foreign
reference. Quote existence does not prove entailment or defeat prompt injection;
gateways must treat source content as data, not instructions.

Request definitions and results have same-corpus foreign keys and SQL immutability.
Jobs claim once outside network locks and recheck authority before retention.
Unknown outcomes never retry automatically; purge cascades through local copies.
Proposals cannot advance a scenario, create labels, approve or compile an eval.
Experts keep the existing revision/review gates. No live scenario endpoint ran.

Model corpus discovery has a third, separate exact workspace/URL registry and
consent bound to the displayed source digest. Conversation/document records alone
enter its bounded payload; unrelated corpora, traces, scenarios and labels stay
local. Frozen input IDs, settings, protocol and UUID cannot be rewritten in SQL.
Results stay immutable and same-corpus; terminal summaries cannot change either.
Every conversation must occur exactly once in the proposed partition. Member and
requirement quotes must exist in the disclosed text; those checks cannot prove
correctness or prevent model injection. The gateway must enforce the data boundary.

The once-claimed job releases locks for transport, then rechecks membership,
source lifetime, current documents, fixed digest and purpose approval before
atomic retention. Revocation/purge during a call discards its returning response;
it cannot recall data already sent. No unknown outcome retries. Mining creates
unapproved versions, grants no target-visible knowledge and creates no labels.
Viewer reads write/queue nothing, and expired inputs hide the derived result.
Configuration is filtered from logs. No live corpus endpoint or customer data ran.

Optional model failure matching requires its own `NAVISHAI_MATCHING_ENDPOINTS`
registry; target, judge, scenario and corpus grants cannot authorise it. A writer
previews one fixed trace and every eligible candidate within strict record/byte
bounds, then confirms the exact endpoint and request digest. Hidden facts, labels,
review history and the separate imported correction stay local. Exact source
quotes do not establish a sound match. Once-only jobs recheck access, lifetime,
candidate freshness and this purpose before/after transport. Copies purge with
the source/scenarios; expired or stale previews hide them. Matching pages use
no-store/no-cache. No association, expectation, label or regression changes.
See [MODEL_FAILURE_MATCHING.md](./MODEL_FAILURE_MATCHING.md).

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
