# Source changes and scenario assumptions

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

Use the existing `ModelGateway` settings and `EvaluationHttp` corpus purpose.
Exact workspace/endpoint approval in `NAVISHAI_CORPUS_ENDPOINTS` and human consent
to the digest-bound preview must precede transmission. Leave registries empty.
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

The nested `assumption_impacts` routes provide an attempt list, local GET preview,
POST request, fixed receipt and POST interruption. Writers can select document
and snapshot IDs from paginated lists and scenario IDs from the corpus scenario
list. Preview freezes those scenarios' current immutable versions. Viewers can
inspect unexpired receipts, but cannot preview, request or interrupt work.

The preview shows both full retained document texts, upload digests, masking
policy/fingerprint/count, import version, importer, intake time, fixed record ID,
external ID, title and retained context. It also shows every selected version's
fixed ID, number, title, origin, author, time and complete assumption fields.
Digests and exact quotes trace retained evidence; they do not certify truth,
PII clearance or relevance. Reviews, labels, model outputs and other corpus
records do not enter the request.

The request form starts with blank model settings and unchecked consent. JSON,
selection, digest or approval errors retain repairable values but reset both
consent boxes. The operator must approve the exact workspace and HTTPS endpoint
for the `corpus` purpose; evaluation/scenario approval does not suffice.
`NAVISHAI_CORPUS_ENDPOINTS` remains empty by default. No built-in provider,
credentials, fallback model or live endpoint is added.

Queued/running receipts have a refresh link. Queued or over-ten-minute running
attempts can be interrupted; a running call may already have left the workspace.
Completed proposals show each fixed scenario, its field, exact assumption and
before/after quotes, reason and uncertainty. They link to the fixed version and
the **current** scenario page for a separate expert revision and fresh review.
Abstention says no supported proposal, not no impact. Error/interruption says
remote outcome/cost may be unknown; neither offers retry or an apply action.

## Structured protocol

`source-assumption-impact-v1` sends one JSON object with `schema`, `instructions`,
`model`, `settings`, `proposal_limit` and the disclosed `input`. Documents and
assumptions are untrusted data, not instructions. Change the protocol version
when its instructions, fields or interpretation change.

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
protocol/settings and exact corpus endpoint approval. Freezing the latest number
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

The bundle adds the routes, three content-free audit actions and one corpus-wide
`SourcePurge` deletion hook. Keep that deletion before scenario removal when
combining lifecycle hooks. Shared navigation must link to
`workspace_corpus_assumption_impacts_path`; no sources controller/show or shared
navigation changed in this slice. Integrate STATUS and a combined native SQL dump
after all worker migrations. Migration ID: `20261002010100`.

The parent privacy work must filter request/body and SQL bind fields `input`,
`result`, `requirements` and `mutation` (alongside existing private facts and
configuration fields). This slice does not edit the shared private-log
initializer. Do not enable a live endpoint before those filters and integrated
privacy checks land.

The existing `db:grant_runtime` grants all runtime tables/sequences in each
production database after schema preparation. No new privilege is needed.
Focused tests use a temporary non-superuser SQL role, transactional native DML
and sequence grants, request/claim/result/purge, refused rewrites and refused
trigger disabling. They do not change deployed grants or prove production
queue/deployment readiness; combined restricted-runtime checks remain required.

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

Result: 44 tests, 480 assertions, no failures, errors or skips. Fixtures include
an unlinked Business-SAML assumption and an unrelated webhook scenario. Checks
prove exact fixed provenance, rejected invented/foreign IDs and quotes, no
authority writes, purpose/consent, historical intent, pre/post-call source and
version changes, change-then-revert, revocation, expiry, corpus-wide purge,
unknown/crashed once-only dispatch, SQL/runtime guards and byte/count boundaries.

The two browser journeys cover empty, expanded preview, repair, queued, proposal,
historical, abstain, error and interruption states. At 1280px and 390px / 2× they
check actual viewport width, overflow, CSP, keyboard disclosure/consent and the
separate current-version expert-save path. Inspected captures live under
`.amp/in/artifacts/assumption-impact/` (`preview`, `repair`, `queued`, `proposal`,
`error`, `interrupted`, each with `-1280.png` and `-390.png`). Expanded provenance
and definitions remain readable; paired evidence stacks on mobile.

`bin/rubocop`: 315 files, no offenses. Brakeman: no errors/warnings.
`bin/bundler-audit` and `bin/importmap audit`: no known vulnerabilities.
`bin/rails zeitwerk:check` and `git diff --check`: pass. Native migration
`db:migrate:redo VERSION=20261002010100` passes down/up in development and test.
These are local fixture checks, not integrated CI, live-model quality or deployed
runtime proof. Parent integration still owns broad combined verification.
