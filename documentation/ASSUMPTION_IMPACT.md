# Source changes and scenario assumptions

## Review correction — 1 October 2026, before follow-up implementation

The first implementation's corpus-purpose choice conflicts with SECURITY.md:
corpus approval covers conversations/documents, not hidden facts or requirements.
Replace it with the distinct `impact` purpose and empty-by-default
`NAVISHAI_IMPACT_ENDPOINTS`. Old corpus/scenario/evaluation approvals must not
authorize this operation, at request, dispatch, transport or result retention.

Keep full fixed provenance and freshness metadata in the immutable local input.
Send only document title/text/context, historical intent and the eligible fixed
scenario reference/title/assumptions. Do not transmit importer/expert IDs,
intake/expiry times, head counters or other local provenance identifiers. Show
the exact canonical JSON body through a local POST preview before consent, bind
that body/settings to a digest, and reject later settings changes. Bump the
protocol to v2 so queued v1 receipts cannot gain this new disclosure scope.
No new role policy, live approval, dependency or shared env/Compose/nav/STATUS
change belongs to this follow-up.

## Decision — 1 October 2026, before implementation

Original Phase E requires product, policy and document changes to identify
possibly stale assumptions, including scenarios without exact links to that source.
`Source#dependent_versions` remains an exact-evidence query. Do not broaden it or
make model proposals affect staleness, approval, definitions, labels or coverage.

Add a separate optional change-analysis receipt. An expert selects one document
source, two ordered immutable snapshots and 1–50 current active scenario versions
from that corpus. The complete preview includes both document records with their
snapshot provenance, and each selected version's situation, known/hidden facts,
requirements, mutation and follow-ups. These existing fields contain assumptions;
there is no new authoritative assumption object. No source link is required.
Selection is explicit, not a claim that the rest of the corpus is unaffected.

One structured model call may propose up to 20 affected versions. Each proposal
must name a disclosed fixed version and field, quote that field and both document
texts exactly, and state a reason and uncertainty. Citation existence does not
prove relevance or truth. Abstention means no supported proposal, not no impact.
Experts inspect fixed evidence and separately open the current scenario editor,
save their own revision and review it. No apply/rewrite action exists.

Use existing `ModelGateway` settings and the distinct `EvaluationHttp` impact
purpose. Exact workspace/endpoint approval in `NAVISHAI_IMPACT_ENDPOINTS` and human
consent to the fixed input and exact wire/endpoint previews must precede
transmission. Leave registries empty. Corpus/scenario/evaluation approval cannot
grant this broader disclosure of hidden facts and requirements.
One call, 256 KiB complete encoded input, 100 KiB response, 256–4096 output tokens,
30-second transport deadline. No silent sampling, truncation, retry or fallback.
Reported usage/cost remain reports; absent values stay unknown.

Allow a deliberately selected historical after-snapshot, with separate human
confirmation. Freeze the source's current head at consent and stop if it advances
before dispatch or result retention. This handles changes between historical
snapshots without mistaking an old comparison for current policy. Recheck selected
scenario heads, merges, rejected reviews, membership, corpus expiry and endpoint
approval at both boundaries. Fixed definitions and terminal receipts are immutable
in PostgreSQL; composite foreign keys bind tenant, corpus, source, snapshots,
selected versions and results. A fixed input/settings attempt is once-only even
when its remote outcome is unknown. A crashed running attempt cannot resume;
experts can interrupt queued or over-ten-minute attempts. New inputs/settings need
a new deliberate preview and consent, and may incur another charge.

Source purge clears these corpus-wide receipts before removing scenarios; expiry
hides their private contents before purge. Sent data cannot be recalled. The
native runtime grant task covers new tables/sequences; deployment must run it
after migration as usual. Rails/Hotwire/native jobs only; no new dependency.

## Ownership and acceptance

This slice owns the new receipt, fixed-input joins, result, service, job,
migration, controller, views and focused tests. Minimal audit/purge hooks belong
to the operation. Parent integration owns shared navigation, STATUS, privacy
filters and combined schema/lifecycle/runtime-grant checks across worker bundles.
No sources-controller/show, landing/discovery, global CSS or private-log changes.

Done checks: unlinked asymmetric assumptions produce inspectable fixture proposals;
invented/foreign IDs or quotes fail; historical consent, changed heads, expiry,
revocation, purge, SQL lineage/immutability, once-only delivery and exact budgets
fail closed; desktop/mobile preview, queued, result and error states render with
native labels, keyboard controls, source links and no overflow/CSP changes.
Fixtures prove contracts, not customer quality. No live data, provider, spend,
training, push, merge, release or deployment is authorized in this slice.

## Built flow

The nested `assumption_impacts` routes provide an attempt list, local GET comparison,
local POST exact-wire preview, POST request, fixed receipt and POST interruption.
The wire preview shares the request route with `preview_only=1`, but starts no
job, receipt, audit event or network call. Its form uses native full-page POST so
private model configuration stays out of URL query strings. Writers select document
and snapshot IDs from paginated lists and scenario IDs from the corpus scenario
list. Preview freezes those scenarios' current immutable versions. Viewers can
inspect unexpired receipts, but cannot preview, request or interrupt work.

The preview shows both full retained document texts, upload digests, masking
policy/fingerprint/count, import version, importer, intake time, fixed record ID,
external ID, title and retained context. It also shows every selected version's
fixed ID, number, title, origin, author, time and complete assumption fields.
Digests and exact quotes trace retained evidence; they do not certify truth,
PII clearance or relevance. All this provenance stays in the immutable local
input. Reviews, labels, model outputs and other corpus records do not enter the
request. Only document title/content/context, historical intent and each selected
fixed reference/title/assumption map enter the wire. Importer/expert IDs, source,
snapshot and record IDs, external IDs, digests, masking metadata, head counters,
origin and intake/creation/expiry times stay local. Content/context can still
contain private data; this projection is not redaction or PII clearance.

The request form starts with blank model settings and no consent/send controls.
An expert previews the complete actual JSON body, including instructions, schema,
model and settings, and its destination endpoint before unchecked consent appears.
The wire/endpoint digest rejects a missing preview or changed endpoint/model/settings;
the full local-input digest separately guards provenance and freshness. JSON,
selection, digest or approval errors retain repairable values but reset both
consent boxes. Invalid JSON hides consent/send until another valid preview.
The operator must approve the exact workspace and HTTPS endpoint for `impact`;
corpus/evaluation/scenario approval does not suffice. `NAVISHAI_IMPACT_ENDPOINTS`
defaults to `[]`. Transport separately checks this purpose and sends an opaque
request UUID and any operator-managed bearer token, never local author metadata.
No built-in provider, credential, fallback model or live endpoint is added.

Queued/running receipts have a refresh link. Queued or over-ten-minute running
attempts can be interrupted; a running call may already have left the workspace.
Completed proposals show each fixed scenario, its field, exact assumption and
before/after quotes, reason and uncertainty. They link to the fixed version and
the **current** scenario page for a separate expert revision and fresh review.
Abstention says no supported proposal, not no impact. Error/interruption says
remote outcome/cost may be unknown; neither offers retry or an apply action.

## Structured protocol

`source-assumption-impact-v2` sends one JSON object with `schema`, `instructions`,
`model`, `settings`, `proposal_limit` and the disclosed `input`. Documents and
assumptions are untrusted data, not instructions. Change the protocol version
when its instructions, fields or interpretation change.

The projected `input` has exactly `historical`, `before`, `after` and `scenarios`.
Each document has `title`, `content` and `context`; each scenario has `reference`,
`title` and the complete `assumptions` map. Payload generation sorts all JSON
object keys but keeps array order/numeric types. Thus the raw JSON in the preview,
the actual transport bytes and the v2 receipt body match even after JSONB storage.
Structured-field quotes use this same sorted encoding. Legacy v1 receipts cannot
dispatch under v2 approval/consent; their pages do not reconstruct a v2 wire.

A successful endpoint response has exactly `schema`, `model`, `decision`,
`reason`, `affected`, `usage` and `cost`. Schema/model must match the fixed request.
Decision is `proposal` or `abstain`; abstention requires an empty affected list.
Usage and cost follow the existing `ModelGateway` report contract and may be null.
They are endpoint reports, not verified bills. Unknown never means zero.

Each proposal has exactly `reference`, `field`, `assumption_quote`, `before_quote`,
`after_quote`, `reason` and `uncertainty`. Reference must be one disclosed
`scenario-version-ID`, once per version. Field must be `situation`, `known_facts`,
`hidden_facts`, `requirements`, `mutation` or `follow_ups`. The assumption quote
must occur in that fixed string or its JSON encoding; document quotes must occur
in both named fixed document texts. All quotes/reasons/uncertainty contain 1–2000
characters after trimming. Unknown keys, invented IDs/quotes, duplicate versions,
wrong schema/model, malformed reports or more than 20 proposals reject the whole
response. No partial proposals survive an invalid response.

Input bounds apply to complete `JSON.generate` wire bytes, including instructions
and settings. SQL preflight counts retained string bytes before loading full
definitions; it omits JSONB number expansion and spacing so they cannot reject
an otherwise valid wire-sized request. Counts above 50 versions, 256 KiB complete
input or 20 proposals refuse rather than sample or truncate. Existing transport
adds public-only DNS checks, pinned TLS connection, no redirects/retries, 100 KiB
response and a 30-second total deadline. Output settings allow 256–4096 tokens;
there is no token-count estimate, verified charge cap or corpus-wide scan.

## Storage and lifecycle

`AssumptionImpact` stores tenant/corpus/source, before/after/head snapshots,
requesting human, full fixed input, digests, settings, protocol, request UUID and
claim times. `AssumptionImpactInput` joins every disclosed immutable version;
`AssumptionImpactResult` stores the validated proposal, abstention or content-free
error. Composite SQL foreign keys prevent foreign-tenant/corpus/source/version
lineage. SQL triggers fix definitions, input joins, claim transitions and terminal
results. Results require a running claim; completion requires its result.

The job claims once on the `evaluations` queue after transaction commit and calls
outside corpus locks. Before transmission and before retaining results it checks
the requesting human's writer membership, current active selected versions,
rejected/merged reviews, expiry, fixed source head, latest snapshot number,
protocol/settings and exact impact endpoint approval. Freezing the latest number
also catches a newer snapshot followed by a return to the old head. Historical
after-snapshots require separate intentional confirmation and never establish
current policy. Later completed receipts remain inspectable with changed-head
and newer-version warnings, not a retroactive rewrite.

A canonical digest sorts JSON objects but preserves array order and numeric
types. A unique corpus/request-digest key reuses the same fixed inputs/settings
attempt even after unknown outcomes, errors or interruption. A crashed claimed
attempt never resumes. New inputs/settings require a new preview and consent;
they may create a new billable call. This is once-only local dispatch, not a claim
that the remote provider has exactly-once semantics.

Any corpus source expiry hides private history and blocks processing. Source
purge removes **all** corpus impact copies before scenarios and analyses, since
the input may contain assumptions derived from other sources. Foreign keys
cascade selected inputs/results on receipt removal. A queued purged job finds
no receipt; a purge/change during transport prevents result retention. Purge
cannot recall data already sent. Audit events retain only actor/tenant/subject
and empty metadata, never input, quotes, model output or credentials.

## Integration and limits

Routes, three content-free audit actions and corpus-wide `SourcePurge` deletion
now join the other lifecycle hooks; deletion precedes scenario removal. Corpus
navigation links to `workspace_corpus_assumption_impacts_path`. The combined native
SQL dump includes migration `20261002010100`; STATUS and the security authority
describe this separate workflow.

The shared transport maps `impact` to `NAVISHAI_IMPACT_ENDPOINTS`, separate from
matching and every other purpose. Environment/Compose entries default to `[]`.
No existing corpus approval expands. Native request/SQL log tests verify filtering
for input, result, requirements and mutation, alongside private facts and settings.
They retain exact database values and prove preview/receipt/transport wire equality.

The existing `db:grant_runtime` grants all runtime tables/sequences in each
production database after schema preparation. No new privilege is needed.
Focused tests use a temporary non-superuser SQL role, transactional native DML
and sequence grants, request/claim/result/purge, refused rewrites and refused
trigger disabling. They do not change deployed grants. Combined runtime/recovery
evidence lives in [OPERATIONS_ACCEPTANCE.md](./OPERATIONS_ACCEPTANCE.md), not a
deployment-readiness claim.

This is an optional selected-set proposal, not discovery of every affected
scenario, a policy diff engine, coverage, a tested live-model claim or a new
source-staleness rule. Exact `Source#dependent_versions` stays unchanged. Only
expert revision/review can change authoritative scenario definitions/approval.
Native styles, disclosures, forms and jobs add no dependency, custom JavaScript
or global CSS. Direct risk review and native security checks replace unavailable
Ponytail Audit and CE Code Review.

## Local evidence — 1 October 2026

Ruby 4.0.6 and locked JSON 2.21.2 run the checks below. Native bundle setup
installed the existing lock; no dependency or tracked lockfile change remains.
The owner's initial-checkout lockfile edit stays untouched in the original root.

```sh
CAPTURE_LAB_SCREENSHOTS=1 PARALLEL_WORKERS=1 bin/rails test \
  test/models/assumption_impact_test.rb \
  test/models/assumption_impact_database_test.rb \
  test/services/assumption_change_analysis_test.rb \
  test/integration/assumption_impact_access_test.rb \
  test/models/source_impact_test.rb \
  test/models/audit_event_test.rb \
  test/services/http_target_transport_test.rb \
  test/system/assumption_impact_journey_test.rb
```

Result after the purpose correction: 48 tests, 559 assertions, no failures,
errors or skips. Fixtures include
an unlinked Business-SAML assumption and an unrelated webhook scenario. Checks
prove exact fixed provenance, rejected invented/foreign IDs and quotes, no
authority writes, purpose/consent, historical intent, pre/post-call source and
version changes, change-then-revert, revocation, expiry, corpus-wide purge,
unknown/crashed once-only dispatch, SQL/runtime guards and byte/count boundaries.

The decisive approval regression supplies all three old approvals together:
corpus, scenario and evaluation cannot queue impact with its registry absent,
wrong workspace or wrong endpoint. Only exact impact approval, fixed local/wire
digests and human confirmation permit the one synthetic transport call. Removing
impact approval blocks the independent transport and pre-call job checks; removing
it during a call discards the response, even while all old approvals remain.
Missing/changing wire preview, endpoint/model/settings changes and legacy v1
consent fail closed. The wire projection test first failed on v1's leaked local
metadata, then passed with exact allowed key sets and unchanged local provenance.

The two browser journeys cover empty, expanded preview, repair, queued, proposal,
historical, abstain, error and interruption states. At 1280px and 390px / 2× they
check actual viewport width, overflow, CSP, keyboard disclosure/consent and the
separate current-version expert-save path. Inspected captures live under
`.amp/in/artifacts/assumption-impact/` in the feature worktree, with review copies
under `.amp/in/artifacts/assumption-impact-v2/` in the parent worktree (`preview`,
`repair`, `queued`, `proposal`, `error`, `interrupted`, each with `-1280.png` and
`-390.png`). The expanded actual wire wraps; paired evidence stacks on mobile.
DOM/browser checks prove consent appears only after local wire preview, remains
unchecked and resets after repair. Preview, transport and stored-receipt JSON
match byte-for-byte. Native keyboard review still creates a new unapproved
scenario version, never applies the proposal itself.

`bin/rubocop`: 315 files, no offenses. Brakeman: no errors/warnings.
`bin/bundler-audit` and `bin/importmap audit`: no known vulnerabilities.
`bin/rails zeitwerk:check` and `git diff --check`: pass. Native migration
`db:migrate:redo VERSION=20261002010100` passes down/up in development and test.
These worker fixture counts are not integrated CI, live-model quality or deployed
runtime proof. [REBUILD_ACCEPTANCE.md](./REBUILD_ACCEPTANCE.md) records combined
verification separately.
