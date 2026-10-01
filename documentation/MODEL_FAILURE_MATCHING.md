# Optional model failure matching

Decision recorded before code, 1 October 2026. This implements one bounded P1
engineering gap from the product reset. It does not establish matching quality.

## Scope and authority

Keep `TraceScenarioMatching` unchanged. Literal matching remains local and the
default. A writer can separately preview one fixed production trace and **all**
eligible current scenario versions in that corpus, then request model suggestions.
The model has no authority to write an association, expert label, expectation,
scenario revision, eval case or regression. Experts use the existing review paths.

Eligibility uses the local matcher's rules: current, unmerged, not rejected,
with linked, unexpired evidence and current company documents. Historical trace
snapshots remain eligible until expiry. Refuse an expired corpus. A changed
candidate set, version, review or document invalidates the preview and stops a
queued or returning attempt; never substitute a newer version.

## Disclosure and limits

Preview the full visible trace input, reported output and reported failure, plus
each candidate's complete title, situation, taxonomy, importance, known facts,
requirements, follow-up plan and exact linked excerpts. Mark requirements as
definitions to compare, not proof that the trace failed them. Do not send hidden
facts, mutation/history, selection reasons, review notes, human labels, the trace's
separate reported-correction field, unrelated records or another workspace.
Linked excerpts may still contain corrections, personal data or secrets. Show
exact IDs and every field before consent. Source text and model prose are untrusted.

Accept 1–20 eligible versions, at most 100 complete linked excerpts, and at most
256 KiB of complete request JSON, including instructions and model/settings.
Count versions and measure retained fields/excerpts before loading their text.
Refuse oversized inputs; do not sample, truncate, shorten or rank away candidates.
One request makes at most one call. The shared strict HTTPS gateway keeps its
30-second deadline, 100-KiB response limit, public-address checks, no redirects,
TLS verification and disabled retries.

Use a distinct `NAVISHAI_MATCHING_ENDPOINTS` operator registry, empty by default.
Its entries use the existing exact workspace/endpoint/bearer-token format. Target,
judge, scenario and corpus approval must not grant matching permission. Credentials
stay in operator configuration. A native labelled checkbox confirms this purpose
and exact contents, and a typed endpoint confirmation binds the human's decision
to the actual destination. A digest binds the preview to fixed contents and
eligibility. Changing model settings cannot expand the disclosed data.

## Execution and output

Store an immutable request definition, UUID, input digest and fixed candidate links.
A native job claims the attempt once, releases locks before transport, then checks
membership, source lifetime, candidate freshness and purpose approval before
retaining one immutable result. Unknown outcomes and interrupted attempts never
retry. A writer may stop queued work or an attempt started over ten minutes ago.
The same trace, input digest and settings return the original attempt, even after
an unknown outcome. Only changed fixed inputs/settings with fresh preview and
consent create a new attempt, never a resend of a claimed UUID.

The strict `model-failure-matching-v1` response contains exactly one decision for
every disclosed version: `match`, `no_match` or `uncertain`, with a reason and
exact quotes from the disclosed trace and that candidate's definition/evidence.
Reject foreign IDs, duplicate/omitted decisions, extra keys and invented quotes
atomically. Quotes prove provenance, not entailment or model accuracy. Retain
reported model, usage/cost and measured elapsed time; unknown cost is not zero.
Malformed output or transport failure remains an execution error, not no-match.

The endpoint returns exactly these top-level keys: `schema`, `model`, `decision`,
`suggestions`, `usage`, `cost`. Schema must equal `model-failure-matching-v1`, model
must equal the request's model, and decision must equal `suggestions`. Suggestions
may appear in any order but must include every disclosed integer version ID once:

```json
{
  "scenario_version_id": 42,
  "decision": "uncertain",
  "reason": "The disclosed trace does not settle this scenario's diagnosis.",
  "evidence": [
    {"reference": "trace-7", "quote": "Assistant resends immediately."},
    {"reference": "scenario-version-42", "quote": "Request quota exhausted"}
  ]
}
```

These IDs/quotes illustrate syntax, not a live or measured match. Each suggestion
needs a nonblank reason and 2–8 nonblank exact quotes, each at most 2000 characters.
At least one quote must come from the trace and one from that candidate's definition
or linked evidence. Valid references are the disclosed `trace-ID`, that candidate's
`scenario-version-ID`, and its disclosed `scenario-evidence-ID` values. Quotes must
occur within a decoded string field, not cross fields or use JSON escape syntax.
Usage is null or `{ "input_tokens": integer, "output_tokens": integer }`, bounded
to 0–1,000,000,000 each. Cost is null or `{ "currency": "USD", "micro_units": integer }`,
with a three-uppercase-letter currency and 0–1,000,000,000,000 micro-units. Null
means unknown. NavishAI adds measured elapsed milliseconds and marks reports as
endpoint-reported; it cannot verify them.

Composite foreign keys keep request/candidate/result links in the same corpus.
Source or scenario deletion cascades through disclosed request/result copies.
Expiry hides them on fresh reads. Matching preview/result pages use `no-store`
and disable Turbo caching. Do not put contents or model reasons in flash, URLs,
audit metadata or error logs. Audit only content-free action/subject IDs.

## Runtime and integration

The migration reuses the native immutable-definition/result triggers. A candidate
delete also purges its whole request, result and remaining candidate links: removing
one join alone would leave private copies in JSON. Existing `SourcePurge` deletes
corpus scenarios and reaches this trigger; trace-item deletion directly cascades.
No separate retention clock extends source lifetime. Stale candidate sets hide old
inputs and results, and expiry hides all matching contents before hourly source purge.

Existing `db:grant_runtime` grants DML on **all** current tables, sequence/schema
usage and default privileges for future tables. These three tables and the
invoker-rights purge trigger use that source of truth; no elevated runtime role or
new grant task is needed. Run native preparation, then
`RAILS_ENV=production bin/rails db:grant_runtime` as the separate preparation owner,
never as runtime.

`.env.example` and Compose now forward `NAVISHAI_MATCHING_ENDPOINTS` with an empty
`[]` default, separate from every other purpose. Shared request/SQL filters cover
input, result and requirements; model-local filters also hide input/result in
inspection. Routes, three content-free audit actions, purge hooks and the combined
native schema are joined. See [REBUILD_ACCEPTANCE.md](./REBUILD_ACCEPTANCE.md) for
combined checks, distinct from the worker evidence below.

## Proof and limits

Use synthetic fixtures and stubbed transport only. Test negation/paraphrase-shaped
responses, strict evidence/ID validation, count/byte refusal, stale consent,
separate-purpose approval, once-only delivery, revocation, deletion and unknown
outcomes. Inspect native disclosure, error, queued and result states on desktop
and mobile. Run native focused tests, Ruby style, eager loading and security checks.
No live calls, customer data, provider spend, training or new dependencies follow.
Implementation and delivery evidence live in [STATUS.md](./STATUS.md).

The opt-in runtime proof is `test/support/model_failure_matching_runtime_proof.rb`.
Run it only against a disposable, fixture-only database: native Rails tests load
fixtures and may replace its schema. Prepare/load the test schema first, then run
the production grant task with all four database URLs pointing to that disposable
database and the preparation-owner username. Run:

```sh
DATABASE_URL=postgresql:///navishai_matching_runtime_proof PARALLEL_WORKERS=1 \
  bin/rails test test/support/model_failure_matching_runtime_proof.rb
```

The proof sets the restricted `navishai` role for matching intake, once-only job
delivery, result retention and source purge. It checks DML grants and denies trigger
disabling and SQL input/result rewrites. It does not prove production deployment,
network isolation, operator approval, semantic accuracy or customer acceptance.
