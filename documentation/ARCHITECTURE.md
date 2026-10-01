# Architecture decision: support evaluation lab

Accepted for the rebuild, 30 September 2026. Scope: a self-hostable first corpus-to-regression workflow. This decision precedes new domain code.

## Decision

Keep Rails, server-rendered Hotwire, PostgreSQL, and Solid Queue. They already cover authentication, isolation, review forms, transactions, asynchronous work, and authoritative records. Keep Go only where it earns a separate execution/network boundary. Remove the old crew execution domain, subscription CLI framework, broad memory service, and deployment machinery coupled to them.

Do not add Python, a warehouse, vector service, or a frontend dependency tree now. Corpus processing and explicit deterministic baselines can use Ruby/PostgreSQL. A later embedding/clustering or classifier workload may use an isolated Python worker if measured quality or scale needs it. That choice needs pinned inputs, bounded jobs, and a separate dependency review, not a second application backend.

## Inventory and disposition

| Existing subsystem | Decision | Reason |
|---|---|---|
| Local auth, verification/reset, invitations, OIDC, first Owner, break-glass | Retain | Independent and tested security controls. |
| Organisations, workspaces, memberships, last-Owner protection | Simplify | Preserve access checks; remove old-domain associations and callbacks. |
| Headers, CSP, rate limits, sensitive-log filters, audit validation | Retain/simplify | Keep proven controls; replace obsolete audit vocabulary. |
| Rails/Hotwire, local fonts, theme and accessible interaction primitives | Retain | No JS-heavy rewrite; new page composition and product language. |
| Intercom two-way sync, email, attachments tied to messaging | Delete | Operational helpdesk duties. Initial intake uses bounded text/JSON exports. |
| Document extraction and guarded HTTP fetching | Evaluate narrowly | Reuse safe primitives only when the new intake/target interface needs them. No legacy converter just for format breadth. |
| Knowledge versions and source reconciliation | Transform | Rebuild as snapshots/corpus evidence, not case applicability. |
| Cases, identities, SLA, account health, scorecards, interventions | Delete | Abandoned product. |
| Crew tasks/profiles/artifacts, policy publication, execution ledger | Delete | Rails ownership depends on crews. New eval records are smaller and purpose-specific. |
| Broad memory, Supermemory, public agent search | Delete | No memory product or open-ended agent tools in the lab. |
| Go process isolation, provider CLIs/vaults, personal accounts | Delete from first slice | No arbitrary local agent process in the first target interface. Git retains these if a future requirement earns reuse. |
| Solid Queue, cache, cable and Rails runtime | Retain | Native asynchronous jobs and deployment foundation. |
| Old installer, release payloads, Helm/native deployment, archives | Delete/replace | They assume the old topology and cannot certify the rebuilt app. Keep a small current Compose path; do not claim old acceptance. |
| Old fixtures, journeys and obsolete docs | Delete | New tests must prove the new contracts, not preserve removed behaviour. |

## Data and reproducibility

PostgreSQL owns tenant state, sources, snapshots, corpus membership, versioned proposals, human decisions, eval definitions, run state, results, and audit. Use explicit schemas for structured content, database constraints for workspace relationships, and immutable versions for retained definitions. A run freezes case, grader, target, and processing settings before execution. Retrying a job must not duplicate logical records or silently call an external system twice after an unknown outcome.

Use a fresh baseline schema for this unreleased product. Do not drop an existing customer database during normal setup. A database with old helpdesk tables must fail the rebuild preflight; operators preserve or archive it and choose a fresh database. Git history, not a live compatibility layer, preserves old migrations.

## Processing

Intake accepts bounded, valid UTF-8 text/JSON, rejects malformed records atomically, records content digests and redaction, and never renders raw HTML. Large work runs through Solid Queue with progress, limits, terminal errors, and attributable settings. Dataset exploration should paginate; analysis must disclose method and limits. Deterministic term/risk mining is a baseline, not a claim of semantic discovery or 100,000-conversation quality.

Normalise and validate masking before snapshot lookup or source mutation, including
repeated uploads. If distinct JSON keys mask to one key, or masked IDs collide,
refuse the whole batch with a content-free repair error. Do not discard either
value, invent replacement keys or change the masking choice. Old retained records
stay fixed; this refusal does not repair them. Snapshot identity includes source,
input digest, redaction, processing version and masking-rule fingerprint in both
lookup and the unique index.
Changed processing creates a new version without rewriting prior evidence.

Validate each source item before inserting at most 1000 rows together. Use one
typed, filtered `content` bind with PostgreSQL `jsonb_to_recordset`, not SQL value
literals that expose retained text/context in Rails DEBUG logs. Keep source,
snapshot, items, retention and audit in the same corpus-locked transaction. A late
invalid item rolls back earlier batches; validation objects never enter the
snapshot's returned association. This changes writes, not intake limits or identity.

Larger conversation intake uses an explicit JSONL format, not raised vendor-export
limits. Bound seekable tempfile reads to one 1-MiB line plus one refusal byte;
allow at most 60 MiB wire, 100,000 records and 256 MiB encoded normalized fields
after masking. The first pass validates structure, masking, identities and bounds
before source mutation, with a digest of exact file bytes. Rewind and feed the
same bounded writer inside the corpus transaction. A changed count/digest or late
model-validation error rolls back all writes. Reuse needs the fixed JSONL processor
as well as existing identity fields. Keep source kind conversations and old
processors unchanged. No background retry, provider call, automatic analysis or
human authority follows intake; the synchronous request waits for the whole commit.

Exact-text masking is a separate, opt-in mode, not an inferred PII policy or an
addition to automatic email masking. The author supplies 1–50 unique UTF-8 values,
one per line, 3–200 characters each and at most 8 KiB total. Preserve spaces and
case; discard empty lines, sort unique values and hash `JSON.generate(values)`.
Match literals left to right, longest first at the same position; never execute
regular expressions supplied by the user. Keep the fixed fingerprint and count,
not the rule list. Reprocessing needs the author's private list and original input.
The existing recursive masker covers keys, strings and arrays, refuses collisions
and revalidates traces. SQL guards bind mode/count/fingerprint and immutable history.
Source names stay unchanged. New rules cannot redact prior snapshots or approve
provider disclosure. Readers must still review retained evidence for sensitive data.

Current analysis previews/requests and fixed processing, mining and overview reads
share a pre-load count and retained-field byte check. Count IDs, titles, text and
PostgreSQL's context JSON bytes, not just conversation text. Hold a short corpus
lock from the aggregate checks through loading; intake/purge cannot change that
collection between them. Refuse oversized historical inputs too, without rewriting
membership, sampling or retrying. Local order stays external ID then ID; model
order stays ID, preserving disclosure digests and batch allocation. Exact encoded
model and per-call limits still apply after this source-row guard. A blocked GET
renders the accessible analysis's state with no partial preview or write controls;
it is not a failed document navigation. POST validation still returns 422.

Partial local reads check the whole fixed input count, bytes and lifetime before
loading only the requested evidence IDs. They cannot bypass those gates or select
new/foreign snapshots. Local overview loads ten examples per displayed family,
selected first with stable ID ties; mining loads chosen records and their linked
model evidence only. Model disclosure previews still contain complete fixed inputs.
Family counts use SQL for exact JSON boolean types and the original Ruby patterns
over complete text in 100-record scalar batches. Keep match IDs, not complete
source objects; load only the fifty records on the filtered page. Hold the corpus
lock through checks, counts and page loading. These changes do not raise analysis
or provider limits, sample membership or change discovery's method.

Local processing uses complete fixed membership with scalar record batches,
global document frequencies and sparse term vectors, not independent batch clusters.
An inverted seed index skips zero-overlap comparisons without changing the
0.3 cosine decision or seed-order ties. Keep full-text signals, centroid selection
and exact provenance. Bulk membership writes remain inside the checked corpus
transaction. First prove the same bounded method's behaviour before adding an
explicit larger-local version; existing model bounds and consent remain separate.

The opt-in larger-local version may freeze up to 100,000 complete records within
1 GiB, using ID-only request reads and bounded membership inserts. Its resource
caps are 2 million conversation-term entries, 250,000 distinct terms and 2 million
seed comparisons. Exceeding a cap fails the attempt atomically, never samples or
continues. Complete evidence views/mining still accept at most 10 MiB per read.
Recheck lifetime/access after computation before committing. Keep the original
local and model definitions/limits unchanged; these are local safety bounds, not
disclosure authority, semantic quality or a claim that every large corpus fits.

Cache vector and centroid squared lengths without changing summation order or
seed ties. Score each candidate seed once. Corpus/source pages also preflight
their fifty complete rows under the corpus lock, keeping full counts and navigation
on refusal rather than loading a fifty-first row or partial content. A blocked
streaming overview retains read-only family links for bounded filtered inspection.

Corpus exploration uses local, case-insensitive literal substring search over
current, unexpired item titles, record IDs, normalised text and JSON context.
Scope source filters to the same corpus before querying. Escape SQL wildcards,
bind values, bound the phrase and paginate 50 records. Show exact source/snapshot
links, not semantic ranking or coverage. Filter search phrases from request logs;
the existing no-referrer policy applies. No model call, search service or new index
is needed for the current intake bounds.

Name the search bind `corpus_query` so Rails can apply the configured private-field
filter to SQL debug values as well as request parameters. The native query already
binds values; do not replace it with interpolated SQL. Active Record shares the
request filter list, including retained content/context. This does not sanitize
PostgreSQL, proxy, browser-history or operator logs outside Rails.

Scenario lookup uses the same private literal bind over current title, situation
and taxonomy label only. Trim the phrase, accept at most 200 characters without
null bytes, and escape SQL wildcards. Under the corpus lock, count the whole
unexpired filter, then load at most fifty scenario IDs and current list metadata
in ID order. Facts, requirements, quotes and old versions stay outside search.
Keep review, merge and source-change states visible; a match grants no authority.

The scenario evidence picker also has a private literal filter over current,
unexpired document titles, source record IDs and text. Count all same-corpus
matches under the corpus lock, but load only the first hundred IDs/titles, not
document bodies/context. Retain the filter on failed revisions and preserve an
explicitly selected trace separately. Lookup cannot attach evidence, change a
version or copy a requirement; the existing expert revision owns those actions.

### Family evidence and error-cost decisions (1 October 2026)

Explore every fixed cluster member through a read-only, scoped and paginated family
page. Count exact uploaded boolean context fields (escalated, reopened, failed)
separately from missing/nonboolean values, literal mentions and reported critical
impact. Apply the same source rules to local/model families without changing fixed
discovery results. A source report or keyword is not a verified support outcome,
risk or label. Filters narrow records, never family denominators or expert authority.

Analysis review can focus all families, those with selected candidates or those
with none. Derive groups from actual fixed member selection reasons, not model
importance or existing scenarios. Count the whole analysis before paginating ten
families. Filtering and refresh change no definitions, selection, totals or jobs;
new exports do not replace fixed membership. These groups describe this method's
selection, not test coverage across the company or other analyses.

Writers may nominate one fixed family record with a bounded reason through an
explicit POST. Reuse mining's corpus lock, fresh role/lifetime/bounds checks and
unique member identity. Create only a local unapproved draft and exact source
evidence; never change fixed selection, model results, expert labels or prior
versions. Repeated nomination opens the existing scenario unchanged. This path
does not reuse a model's proposed expectations or request a provider call.

Calibration sets may fix optional human-supplied false-positive/false-negative
costs, common units and rationale with the existing creator/version attribution.
No defaults, inferred values, currency choices or live-spend authority. Store exact
non-negative bounded decimals, reject unsupported precision rather than round it,
and require the whole assumption group or none. Existing sets remain unknown.
Report weighted observed mistakes only among comparable certain labels, separately
by cohort and candidate; zero comparable samples remain unknown. These are supplied
assumptions, not verified business costs, deployment decisions or a universal score.
Changing assumptions requires a new set; no labels/predictions/history are rewritten.

Machine proposals never approve themselves. Experts correct taxonomy and scenario expectations before compilation. Calibration binds labels to exact grader/output versions and separates held-out examples. Store individual decisions, not an opaque score.

Calibration review uses the same latest-per-expert labels and fixed predictions as
its cohort report. Show missing personal labels first, then expert disputes,
uncertainty, machine/expert disagreement and missing usable predictions. Before an
expert's first label, every sample has the same unlabelled state regardless of other
labels or predictions. Filters change only the review list, never the report's
denominator. This read-only queue asks for review; it cannot settle a dispute,
relabel, tune a grader, select an error cost or call a provider.

Development previews reuse the report and fixed sample artifacts, not another
trial table. A newer deterministic version of the same grader runs locally against
development outputs after rechecking case eligibility. Keep its report separate
from saved predictions and the original review queue. Do not write predictions,
labels or approvals; refuse held-out data and judge execution. Candidate counts
use current expert labels on original requirements, not labels approving the
candidate. Changed meaning needs new labels; any revision needs fresh held-out
calibration. Personal first-label hiding also applies to candidate disagreements.

## External execution

### Bounded incremental conversation decision (1 October 2026)

Expert-authored immutable follow-up plans remain local until a literal condition
matches the latest assistant reply. One generic `http_conversation` adapter uses
`support-conversation-v1`, the existing endpoint-purpose registry and guarded HTTP
transport. Consent binds fixed cases, planned messages, transcript forwarding and
the maximum eleven calls per case. Single-shot adapters reject planned cases.
Start with the visible situation as a user turn; never send future messages, hidden
facts, expectations or labels. Literal matching is not semantic correctness.
Recheck access, run state, source/approval lifetime and endpoint authority around
each unlocked call. Once-claimed runs never retry unknown calls. Turn keys derive
from the item UUID and index; content-free receipts accompany execution results.
Only a fully validated aggregate transcript is a successful output. Ordered tool
and citation reports do not prove tools ran. Existing adapters and processing
versions retain their semantics. No vendor integration or generated authoritative
dialogue is introduced.

Start with one generic structured target interface and a scripted adapter for contract tests. Rails does not execute model CLIs or shell commands. Use Solid Queue jobs for the first bounded batch, not a second worker language: there is no customer process to isolate. The HTTP adapter uses Ruby's standard HTTP/TLS capabilities, explicit endpoint approval, DNS/IP checks and connection pinning, no redirects or proxy inheritance, deadlines, bounded JSON and no credentials in logs. Go earns a return only when a separate process/network boundary reduces real risk or measured load. The domain branches on check/capability types, not vendor names.

Provider disclosure is off unless an authorised human configures and starts it. Do not send hidden expected outcomes to a target. Send only the case's visible context and permitted knowledge. Judge calls may receive the frozen rubric and relevant evidence; source content remains untrusted. Record model/settings, attempts, usage when supplied, and unknown cost honestly.

The first execution proof uses a local declarative script: ordered rules compare one
known fact and return a validated support-output-v1 fixture. It cannot run code or
read hidden expectations. Call it a scripted fixture, never a live agent or judge.
Runs freeze target versions, case membership and target-visible input, and contain
at most 50 cases and 100 checks. A job claims a run once; repeated delivery cannot
execute it again. A crash after claiming leaves an interrupted/unknown outcome,
not permission to retry an external call. An expert may stop an old claimed run
and deliberately start a new run. Immutable results distinguish reported behaviour,
abstention and execution errors. A regression records the exact failed result,
case, human and reason; adding it never silently rewrites the case.

Response-scoped deterministic checks bind a user phrase to its following assistant
reply block, ending at the next user message. All matching turns must satisfy the
required/forbidden phrase; missing or blank replies fail. The v2 check definitions
retain the existing v1 output schema and old check semantics. These are literal
reported-transcript checks, not an interactive conversation runner or proof of
incremental target input. Hidden facts stay outside target input.

HTTP definitions bind only an endpoint. The operator's private environment
allowlists exact HTTPS port-443 URLs per workspace and holds optional bearer tokens;
an expert must also confirm visible-input disclosure for each requested run.
The confirmation binds the reviewed case list; a membership change blocks any
external run, not only runs with configured judges.
The versioned support-target-v1 interface sends only that preview and receives
support-output-v1. Each run item has an immutable request UUID. The worker claims
once, checks access/evidence under short locks, releases them before execution,
then checks again before retaining a result. An in-flight request cannot be recalled
on revocation or deletion; changed access/evidence discards its local response and
stops later cases. No automatic retry or remote exactly-once claim. Endpoint
operators own idempotency and remote retention. Private-address targets stay denied;
deployment egress policy must enforce the same boundary. No live target is configured
by default. See [the interface and bounds](./DEVELOPMENT.md#generic-http-target).

Rubric judges use the same approved JSON transport, not a second network client.
Each definition fixes its model, settings, rubric and threshold. A separate consent
binds the displayed suite cases and their judge endpoints; target consent cannot
approve judge disclosure. Only the requirement, visible context, exact company
excerpt and recorded output enter support-judge-v1. Labels and hidden facts stay
local. Quotes must occur in those inputs; that check does not prove sound reasoning.
Low confidence abstains, malformed responses are errors, and reported usage/cost
remain reports. A calibration judge attempt claims once outside network locks and
retains one immutable prediction beside human label history. Endpoint operators
own model execution, settings enforcement, deduplication and remote retention.
There is no direct vendor integration or proof of live judge quality.

## Source-backed model proposals

Extend scenario extraction without making a model authoritative. One requested
proposal binds to an immutable scenario version, its exact evidence excerpts,
model/settings and protocol. Reuse the bounded HTTPS transport and native job
claim pattern. Keep a separate `NAVISHAI_SCENARIO_ENDPOINTS` operator registry:
target or judge endpoint approval never grants source-processing permission.
An expert must confirm this version's disclosure on the request form too.

Send only the starting situation, known facts and up to 20 linked excerpts within
64 KiB. Omit hidden facts, existing expectations, reviews, labels and the rest of
the corpus. Source text remains untrusted. Proposed requirements each need an
exact quote from one disclosed excerpt; this proves provenance, not entailment or
correctness. Abstention and execution errors remain distinct from a proposal.

Retain the immutable proposal beside its fixed input version, reported usage/cost
and elapsed time. Never advance the scenario, approve it, create a human label,
compile an eval or overwrite an expert edit. Experts use the existing version and
review workflow to make any proposed expectations authoritative. One attempt per
version claims once, sends outside locks, rechecks membership/source/endpoint
authority before retention and never automatically retries an unknown outcome.
Deletion cascades from source-backed scenarios through these request/results.
This is a bounded extraction interface, not semantic corpus clustering or proof
of model quality. It adds no vendor SDK, training or production dependency.

## Model-assisted corpus discovery

Keep local discovery and add an explicit model method to the same analysis domain.
Freeze all current conversation/document item IDs, their exact input digest,
model/settings, protocol and request UUID. The first model request accepts at most
100 complete records, 256 KiB and 20 candidates; it neither samples nor truncates
silently. The bounded multi-request method below handles larger disclosed inputs.

Corpus disclosure needs `NAVISHAI_CORPUS_ENDPOINTS` and consent bound to the exact
preview digest. Neither target/judge nor single-scenario approval covers full source
records. Send source titles, text and retained context only; omit scenario
expectations, expert labels, traces and other workspaces. Reuse the guarded transport.

The response proposes company-specific families, an explained partition of every
disclosed conversation and bounded scenario definitions. Every member and proposed
requirement needs an exact disclosed quote. References, duplicates, omissions and
invented quotes fail atomically. Counts come from actual membership, not model
coverage claims. A documentation-gap proposal remains a proposal.

Claim once, release locks while processing and recheck membership, source lifetime,
document freshness and purpose approval before saving immutable results/clusters.
Unknown outcomes never retry. Experts may interrupt old attempts and deliberately
request a new analysis. Taxonomy review and scenario mining reuse their existing
human gates. Mining copies proposed definitions and exact expectation evidence;
it grants neither approval nor target-visible knowledge. No classifier or new
dependency follows from this method; fixture responses cannot prove its quality.

### Bounded multi-request discovery

Extend the same analysis with an explicit batch method; keep the single-request
method unchanged. Freeze up to 2000 complete records within 10 MiB. Pack ordered
conversations into requests that each satisfy the existing 100-record/256-KiB
bound, with every current document repeated as shared company evidence. Reject
an unfit record/document set or more than 30 discovery batches before queuing.
Consent binds this exact source digest, record allocation and maximum call plan:
one call per batch and at most one reducer call to the same approved endpoint.

Persist each fixed batch/UUID, once-only claim and immutable result. Recheck source,
document, membership and corpus-purpose authority before and after every call,
without holding locks over transport. Interruption, abstention, malformed output,
revocation or an unknown outcome stops later calls and prevents global proposals.
Batch receipts remain inspectable; they do not form a partial authoritative dataset.
No automatic continuation or retry follows a crashed claimed analysis.

A reducer groups already-validated batch cluster references and selects from their
candidate references. It cannot create members, quotes or scenario definitions.
Compose global membership and expectation evidence locally from those fixed
results; do not ask a bounded model response to repeat thousands of source quotes.
Require an exact partition of all batch clusters and unique candidate selection.
Reject more than 200 intermediate clusters or a reducer payload over the shared
1-MiB transport bound instead of dropping families or proposals. Derived proposals
are untrusted data from the same endpoint, not expert labels. Final selection is
bounded by the requested candidate limit and still needs expert review.

## Production failures

Treat uploaded production traces as source records, not a tracing service. The
bounded `support-trace-v1` format retains visible input, a `support-output-v1`
output, target version, observation time, reported failure and reported correction.
Reuse immutable snapshots, email masking, provenance and source retention. A report
is not an expert label. Creating a candidate copies the starting situation and
known facts, leaves requirements empty and requires the existing expert review.
Experts attach current company evidence and choose permitted knowledge themselves.
Do not fold trace payloads into the term-discovery baseline.

Recorded replay binds a target version to an exact trace item through a
same-corpus foreign key. It may return that output only for identical visible
input; changed context must not inherit an old answer. Replay is local, not a new
agent execution. Compatibility discovery compares every fixed case with the
retained trace in PostgreSQL, binding only its ID and the expiry time. No input
text enters SQL parameters or logs. JSON object order is irrelevant; fact types,
array order and ordered knowledge references/excerpts stay exact. Scope the trace
to the case's workspace/corpus and an unexpired trace source. Count all matches,
then select only 50 case IDs/titles for that record's independent page. This does
not establish common meaning or execution eligibility; old cases remain historical.
Judges retain their separate disclosure gate. Existing fixed
results and human regression admission own the failure-to-regression path.
Source purge must clear all corpus scenarios, including trace proposals that have
no analysis parent, before deleting their evidence. No semantic failure matching,
automatic authoritative correction, provider call or classifier training follows
from importing a trace.

### Reviewable failure matching

Add local candidate retrieval across current, unmerged, fresh scenario versions in
the same corpus, not looser recorded replay. Disclose the bounded search and exact
shared terms/facts, conflicting facts and source/version links. Literal overlap
can suggest a review but cannot establish the same issue, diagnosis or expectation;
no semantic accuracy, probability or coverage follows from it. Hide expired derived
content. Do not use imported corrections as labels or send data to a provider.

Keep explicit human selection separate from retrieval. A scoped scenario-ID GET
inspects one chosen current version for a trace on the displayed source page,
without a write or a search-cap change. Reuse the existing association validator
and revision editor. Failed stale writes retain the submitted fixed version;
never substitute a newer version for that decision. Foreign IDs reveal no title,
and rejected/merged/stale choices cannot gain a decision form.

Count current unmerged version IDs in SQL before loading candidate definitions
or evidence associations. Refuse above 2000; never take the first 2000 as a sample.
Hold the corpus lock through count and loading so normal scenario writes/purge
cannot change membership between them. Load that collection once for the page's
traces. Read byte lengths and link/review metadata first, using the same eligibility
rules. Refuse above 10 MiB before searched strings/excerpts load; preserve UTF-8,
joining newlines, ordered prefix bytes and no-sampling semantics. Then read only
matching version fields, known facts and searched expectation quotes. Keep all
evidence IDs/source metadata for decision freshness, but no unused source bodies,
context, hidden facts, contract statements or ignored quote text. Native scoped
preloading shares this link projection across the two passes. Returned records
are read projections; full definition pages and explicit permitted-knowledge reads
remain separate. This is not a cap on every metadata allocation or semantic proof.

Intersect literal terms before tokenizing fact JSON. Fewer than two raw shared
terms cannot pass after fact-word exclusion, so skip that unused work. Keep the
post-exclusion threshold, full searched membership and bounds unchanged.

Rank by summed term rarity rather than raw overlap count. Reuse local discovery's
inverse-frequency weighting: each distinct shared term contributes
\(\ln(1 + N / d)\), where \(N\) is all eligible searched current versions and \(d\)
is the number containing that term. Count a term once per definition across its
searched fields; repeated occurrences and query words cannot boost it. Compute
these frequencies once for the page's traces, after the existing refusal checks.
Exclude fact words from each candidate's scored overlap as before. Sum terms in
sorted order; equal-fact count and version ID break score ties.

Common symptoms can otherwise displace a rarer diagnostic term. This weighting
addresses that lexical case, not causal understanding. Retain conflicting facts,
exact source links, score contributions and the explicit human selection path.
Scores change with eligible corpus membership and cannot measure confidence,
compare corpora, resolve negation or find zero-overlap paraphrases. No new storage,
provider disclosure, model, dependency or authoritative decision follows ranking.

Experts may append match/different/uncertain decisions with a reason on an exact
trace item and current scenario version. Retain each author's history; later
corrections append rather than rewrite it. Same-corpus foreign keys, immutability,
source lifetime and deletion govern these records. A match neither rewrites a
scenario nor approves a trace, grants knowledge, compiles a case or admits a
regression. The expert can open the existing scenario or propose a separate one;
changed input still cannot replay an old output. Meaningful retrieval quality
remains a pilot question, not a fixture claim.

An expert can open that exact version with a retained trace selected as additional
evidence. This is a read-only entry into the existing revision form, not an update
or approval. Starting facts, requirements and excerpts never copy imported
corrections automatically. The expert chooses an exact excerpt, edits behaviour,
saves a new version, reviews it and compiles it separately. Current documents and
all unexpired fixed trace snapshots may supply evidence; a later trace export does
not erase a historical failure. Distinct conversation/trace records remain additive
even within one source. Replacing prior same-use evidence by source applies only
to current documents. Prior versions, cases and association decisions stay fixed.

## Source impact and run comparisons

Keep impact queries on `Source`: follow exact snapshot/item evidence into fixed
scenario versions, cases and suite membership. Show current and historical
dependencies. A changed document makes its old evidence stale; a changed export
does not invalidate history. Do not infer semantic impact or rewrite expectations.
Expired corpus sources hide these derived records under the existing lifetime gate.

Keep comparisons on `EvaluationRun`: join only the same fixed case and identical
frozen visible input within one corpus. Changed definitions or inputs stay
unmatched. Pass → fail is a reported regression; fail → pass is recovery. Missing,
error and incomplete results stay unresolved, not improvements. Link the exact
results and disclose unmatched membership rather than inventing a support score.
These read-only views need no new tables, provider calls or dependencies.

## Isolation, deletion, and hosting

Every controller and job starts from a checked workspace. Composite relationships prevent foreign evidence and definitions. These checks are not PostgreSQL RLS and must not be described as such. Source retention/deletion must remove content and dependent disclosed copies under explicit policy while preserving a minimal non-content audit. Raw data, redacted snapshots, labels, and outputs have separate lifetimes.

Keep deployment boring: web, jobs, PostgreSQL, and only the execution worker actually needed. No runtime CDN or telemetry. Existing installer/live-host proof does not transfer to this topology. Validate backup/restore, network policy, TLS, and clean-host setup before claiming deployment readiness.

Prepare production schemas once under a separate database owner before starting
web/jobs. Runtime uses a distinct password and a non-superuser, non-owner role with
table DML, sequence usage and schema usage only. It cannot create databases/roles,
change schemas, assume the preparation role or disable audit/version triggers.
Never run migrations from web startup or pass the preparation credential to a
persistent app process. The three-service topology stays unchanged.

## Alternatives rejected

- Preserve and rename crews: carries persona, helpdesk, and policy state into eval ownership.
- Rewrite the control plane in Python or a SPA: adds two migrations of risk without a demonstrated workload need.
- Retain the full runner for hypothetical targets: keeps a large process/credential surface that the first HTTP target does not need.
- Universal taxonomy and all-LLM grading: loses company judgment and makes simple checks costly and uncertain.
