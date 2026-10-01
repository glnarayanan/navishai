# Proposed failures from production traces

This opt-in batch operation can find proposed failures in uploaded
`support-trace-v1` records **without an uploader-reported failure**. It also proposes
emerging issue families and gaps against the disclosed scenario/case set. These
are uncalibrated model proposals, not labels, verified failures, passes, measured
coverage, scenario matches, approvals or regressions.

Import, preview, refresh, review and draft creation send nothing to a model.
Only a deliberate, confirmed request can enqueue one model attempt. Single-trace
matching remains a separate workflow. Discovery does not rank existing scenarios,
run a target, call a judge, train a classifier or change a taxonomy.

## Request and disclosure

Open the corpus's nested `trace_failure_discoveries/new` page. Writers can review
the complete frozen preview; viewers can inspect retained attempts but cannot
request, interrupt, review or draft. Review the data for private information:
email/exact-text intake masking does not guarantee full PII removal.

The preview includes:

- Every complete trace from current trace snapshots, including recorded input,
  output, knowledge, facts, reported failure/correction and retained context.
- Every complete current company document, with retained context.
- Every current, unmerged scenario definition, including known/hidden facts,
  issue-family labels, requirements, follow-up plans, linked exact excerpts and
  latest review decision.
  Historic linked sources disclose only those excerpts, not their whole content.
- Every compiled case on those definitions, including its contract, compiler
  version, eligibility and versioned grader/check definitions.

Expert notes, human labels, reviewer identities, targets and other tenants are not
part of the request. Definitions and reports are evidence, not a claim that the
historic answer was correct. All supplied content remains untrusted data.

Engineering bounds are 1–50 traces, at most 50 documents, 50 current scenario
definitions, 50 compiled cases, 200 evidence links and 200 check links. Complete
encoded input must fit within 256 KiB. SQL counts and retained-field byte sums run
before full reads; the encoded check follows. The corpus lock covers both stages.
Oversize, empty, stale or expired input blocks the whole preview/request. There is
no sampling, splitting, truncation or partial finding retention.

The writer supplies the native `ModelGateway` configuration:

```json
{
  "endpoint": "https://operator.example.invalid/structured-model",
  "model": "operator-fixed-model-version",
  "settings": { "temperature": 0, "max_output_tokens": 4096, "seed": 29 }
}
```

Use no credentials in this JSON. Native limits allow `max_output_tokens` 256–4096
and a null or integer seed from 0 through 2147483647. The operator must approve the exact
workspace/endpoint in **`NAVISHAI_TRACE_DISCOVERY_ENDPOINTS`** for the separate
**`:trace_discovery`** purpose. Corpus, target, judge, scenario and matching
approvals do not grant it, even for the same workspace/endpoint. Corpus approval
covers source-record processing, not this trace/definition/case disclosure.
The new registry defaults to `[]`; leave entries empty until an operator grants
this exact purpose. Approval does not supply user consent: the writer must
separately confirm the exact shown contents, trace-discovery purpose, endpoint,
model and settings through `trace_discovery_disclose`. A corpus-consent parameter
cannot grant it. A changed preview clears consent and starts nothing. The preview
digest sorts object keys recursively without changing array order or numeric types.

## Versioned wire contract

`TraceFailureDiscoveryProtocol::VERSION` is `trace-failure-discovery-v1`. The native
gateway receives the frozen input plus `schema`, fixed `instructions`, `model`,
`settings` and `group_limit` (20 per category). Trace/document references use
`corpus-item-ID`; definition references use `scenario-version-ID`; compiled cases
use `eval-case-ID`. The fixed request UUID is the native idempotency key. Remote
idempotency, retention, billing and deletion remain the endpoint operator's duty.

The response accepts **exactly** these top-level keys:

```json
{
  "schema": "trace-failure-discovery-v1",
  "model": "operator-fixed-model-version",
  "decision": "proposal",
  "reason": "Possible unsafe replay; expert review required.",
  "trace_accounts": [
    {
      "reference": "corpus-item-1",
      "decision": "proposed_failure",
      "reason": "The recorded output proposes a destructive retry.",
      "evidence": [
        { "reference": "corpus-item-1", "quote": "I replayed the destructive delete." }
      ]
    }
  ],
  "emerging_families": [
    {
      "label": "Destructive retries",
      "reason": "The disclosed case checks certificate expiry, not destructive retry handling.",
      "members": ["corpus-item-1"],
      "comparison_refs": ["scenario-version-2", "eval-case-3"],
      "evidence": [
        { "reference": "corpus-item-1", "quote": "I replayed the destructive delete." },
        { "reference": "scenario-version-2", "quote": "Collect certificate expiry." }
      ]
    }
  ],
  "coverage_gaps": [],
  "usage": { "input_tokens": 400, "output_tokens": 120 },
  "cost": null
}
```

The example assumes exactly one disclosed trace and the two listed comparisons;
IDs and quotes must come from the actual preview. Each trace appears exactly once
as `proposed_failure`, `no_finding` or `abstain`, with a reason and evidence array.
Each proposed failure needs an exact quote from that trace. No finding is not a
verified pass. Whole-request `abstain` requires an abstention account for **every**
trace and empty family/gap arrays.

Both group categories use the same strict shape. Each group has unique disclosed
trace members, an exact quote from each member, all disclosed scenario/case
references in `comparison_refs`, and at least one exact comparison quote when
that set is nonempty. Comparison quotes must occur in the disclosed JSON
definition/case record; trace/document quotes must occur in its complete `content`.
An empty comparison set cannot prove a company-wide gap. Groups may overlap and
may use no-finding/abstaining traces as evidence of missing incident context; this
does not change those trace decisions. Groups do not create taxonomy records.

Labels fit 120 characters; reasons and each quote fit 2000; an evidence array has
at most 100 unique entries. Extra keys, authority/confidence fields, null bytes,
invented quotes, foreign/duplicate/missing references, incomplete comparison sets
and unsupported model/schema values reject the **whole response**. Native
`ModelGateway.valid_report?` validates nullable usage/cost; missing values remain
unknown, not zero. The receipt adds local elapsed milliseconds and marks cost as
endpoint-reported, not verified.

Gateway/validation errors store a content-free error reason, empty account/group
arrays and every frozen trace reference in `unassessed_traces`. This is an execution
error, never a discovered failure. No partial model text survives validation.

## Claim, lineage and lifecycle

The request freezes the configuration, input, digest, protocol version, UUID,
requesting expert and time. PostgreSQL composite workspace/corpus foreign keys
link every copied source item, scenario version and compiled case to the request.
Linked historical excerpts also retain source-item lineage. The response belongs
to that exact tenant/request; expert decisions bind to one of its input items.

The job claims `queued → running` under the corpus/request locks once, then drops
locks during the network call. It rechecks requester access, endpoint purpose,
source lifetime and the complete document/definition/case comparison set before
sending and before saving. New trace exports do not widen a fixed historical
request; later documents, definitions, reviews or compilations require a new
preview. Source purge, expiry, revocation or a changed comparison set discards an
in-flight response. A redelivery cannot resend a claimed or terminal attempt.

Requests allow only `queued → running/interrupted` and
`running → complete/interrupted`; SQL guards reject definition changes and terminal
rewrites. Results, input joins and reviews reject updates at the model and SQL
levels. One result per request is unique. There is no automatic retry after a
crash or unknown remote outcome. Writers can interrupt queued attempts or running
attempts older than ten minutes; interruption does not cancel a remote call or
claim a known remote cost.

Expiry hides all retained input, findings and expert reasons on the page and
blocks new reviews/drafts. `SourcePurge` deletes corpus-wide discovery requests
before existing corpus descendants, as that service already removes dependent
eval/scenario state. SQL `BEFORE DELETE` hooks on linked `corpus_items`,
`scenario_versions` and `eval_cases` also delete the **whole disclosure**, including
request/result/reviews, rather than leaving a partial snapshot. Workspace/corpus
deletion cascades through the same lineage. Audit IDs/actions survive without
private content; local deletion cannot recall data already sent to an endpoint.

Four content-free audit actions are allowlisted: `trace.discovery_requested`,
`trace.discovery_completed`, `trace.discovery_interrupted`, and
`trace.failure_reviewed`. Model failures count as completed attempts with error
receipts, not successful discovery. Existing `scenario.mined` records draft
creation separately.

Private JSON columns use `input_content` and `result_content` to reuse the native
`content` parameter/SQL-bind filter even on this exact base. Configuration and
expert reasons reuse existing filters. Tests exercise actual DEBUG INSERT binds
and object inspection. Filters do not protect arbitrary output, SQL literals,
database/proxy logs or an endpoint's logs. Workers log IDs/error classes, not
request bodies or remote error text.

## Expert handoff

Experts append accept, reject or uncertain decisions with their own reason.
These decisions are not `HumanLabel` records or calibrated grader results. The
latest acceptance **by the drafting expert** permits a deliberate draft action;
another expert's acceptance does not grant it. Changed/expired evidence blocks new
decisions and draft creation.

`SupportTrace.propose!(discovery_review:)` reuses the existing trace→scenario flow.
It uses the recorded starting situation/facts and the exact reviewed source quote,
even when the quote lies beyond the old 4000-character window. Requirements stay
empty. Machine explanations, family labels and uploader corrections do not become
authoritative expectations. Existing source-backed drafts remain unique and
repeat draft requests return the existing scenario after review/lifetime checks.
Experts must write source-backed requirements, review the new version, compile it
and deliberately admit appropriate run failures to regression through the existing
workflow. Discovery never performs those steps.

## Integration and evidence

Corpus navigation now links to `workspace_corpus_trace_failure_discoveries_path`.
The central authorities describe the workflow; routes, four content-free audit
entries, corpus-wide `SourcePurge` deletion and the optional `SupportTrace.propose!`
handoff are joined. Shared privacy checks cover request/result/review copies.

Operator environment/Compose entries now forward `NAVISHAI_TRACE_DISCOVERY_ENDPOINTS`
with an empty `[]` default and its own disclosure scope. The shared gateway
map adds only `:trace_discovery`; it grants no other purpose and has no live entry.
Revoking this approval blocks queued sends and discards in-flight responses even
when every other purpose remains approved. Tests prove both boundaries through
the native gateway, including its distinct credential and no retry.

Migration `20261001230000` creates six operation-specific tables, SQL foreign keys,
immutability guards and deletion hooks. Its timestamp leaves `210000` and `220000`
to the scenario-quality slice. The combined native `db/structure.sql` includes all
joined migrations. Production preparation must run
the existing owner-only `db:grant_runtime` after schema preparation for all four
databases. It already grants all tables/sequences and future defaults to the
restricted `navishai` role; there is no per-table list or new privilege here.
Do not run the application/worker as the schema owner or disable these triggers.
The focused model test proves the same DML/sequence grants with a disposable
restricted local role, including six trigger-disable denials and source purge.
Its fixture transaction rolls the role/grants back. On a non-superuser test
database this proof skips explicitly; it never elevates the application role.

Focused checks use only synthetic traces and stubbed native HTTP responses:

```sh
PARALLEL_WORKERS=1 bin/rails test test/models/trace_failure_discovery_test.rb \
  test/models/trace_failure_discovery_delivery_test.rb \
  test/services/trace_failure_discovery_preview_test.rb \
  test/integration/trace_failure_discovery_access_test.rb
CAPTURE_LAB_SCREENSHOTS=1 bin/rails test \
  test/system/trace_failure_discovery_journey_test.rb
```

These prove workflow/security contracts, not useful discovery on unseen company
data, model accuracy, completeness of company policy, true coverage, commercial
cost or live-provider quality. No real data, paid call, dependency, deployment,
automatic scenario approval or regression admission forms part of this evidence.
