# Source-backed model corpus observations

This adds review proposals to model corpus discovery. It does not define a
universal company taxonomy or turn historical answers into expert truth.
The joined services, request selection, fixed plans, job registration and result
views retain the same versioned contract.

## Versions

| Fixed analysis method | Discovery response | Reducer response |
|---|---|---|
| `support-corpus-v1` | `support-corpus-v1` | None |
| `support-corpus-batch-v1` | `support-corpus-v1` | `support-corpus-merge-v1` |
| `support-corpus-v2` | `support-corpus-v2` | None |
| `support-corpus-batch-v2` | `support-corpus-v2` | `support-corpus-merge-v2` |

`VERSION` and `MERGE_VERSION` remain v1. The additive constants are
`ModelCorpusDiscovery::OBSERVATIONS_VERSION`,
`BatchCorpusDiscovery::OBSERVATIONS_VERSION` and
`BatchCorpusDiscovery::MERGE_OBSERVATIONS_VERSION`.
`ModelCorpusDiscovery.protocol_for(analysis)` derives the wire version from the
fixed analysis method, never from the endpoint's response. V1 still rejects
observations; v2 requires them. Neither version accepts the other's result.
Mixed discovery/reducer versions fail rather than drop observations or reinterpret
old receipts. No historic rows or saved expert decisions change.

## Discovery contract

V2 retains the exact v1 cluster, partition, candidate and source-quote contracts.
Its response has exactly `schema`, `model`, `decision`, `reason`, `usage`, `cost`,
`clusters`, `candidates` and `observations`. A proposal may have no observations.
Abstention requires all three arrays empty; missing evidence is not a finding.

`observations` contains 0–100 members per discovery request. Each has only:

```json
{
  "kind": "contradictory_guidance",
  "status": "proposed",
  "summary": "The macro puts rotation first; the playbook puts evidence first.",
  "uncertainty": "The dates and scope may differ. An expert must check both.",
  "evidence": [
    { "reference": "corpus-item-123", "quote": "Rotate before collecting expiry." },
    { "reference": "corpus-item-456", "quote": "Collect expiry before changing configuration." }
  ]
}
```

This example describes the shape, not real customer evidence. References must
identify records in that exact disclosed request. Quotes must match their source
content exactly, including case, spaces and Unicode. Titles and context are not
substitutes for content quotes. Summary, uncertainty and each quote must be
nonblank, contain no null byte and use at most 2000 characters, including padding.
No field is trimmed, filtered or shortened. Each evidence array has 1–8 distinct
reference/quote pairs. These kinds need at least two anchors, which may come from
one record: `contradictory_guidance`, `agent_disagreement`, `false_resolution`,
`reopen`, `customer_variant`. They retain both reported sides, closure and later
failure, or contrasting customer conditions for expert inspection.

Supported kinds also include `policy_exception`, `diagnosis_vs_guess`,
`escalation`, `documentation_gap`, `issue_vs_symptom`,
`troubleshooting_progression`, `reproduction`, `configuration_vs_defect`,
`environmental_dependency`, `integration_dependency`, `workaround_vs_resolution`,
`partial_resolution`, `engineering_handoff`, `evidence_sufficiency`,
`required_logs`, `customer_vs_agent_action`, `product_limitation`, `known_issue`,
`incident`, `entitlement`, `repeated_contact`.
These are support distinctions, not company issue labels. There is no quota per
kind and no demand to manufacture a finding when evidence is sparse.

Every member must pass. Unknown fields/kinds, malformed members, missing
uncertainty, duplicate anchors, foreign references, invented quotes and any
exceeded bound reject the whole response. Exact quotes prove retained provenance,
not entailment, sound diagnosis, a correct exception or genuine resolution.
`status` can only be `proposed`; no confidence or accuracy score supplies authority.

## Batch contract

Call `BatchCorpusDiscovery.plan(items, version: fixed_batch_version)` when showing,
freezing and rechecking consent. Omitting `version` retains the old plan exactly.
A v2 plan adds `schema: support-corpus-batch-v2` and
`discovery_schema: support-corpus-v2` and, when needed, selects the v2 reducer.
The plan digest thus distinguishes v2 even for a single batch without a reducer.
Record allocation, complete documents, source digest and maximum calls stay the
same: one call per discovery batch, plus one reducer only when there are several.

Reducer input retains all complete validated observations under `observations`:
`{"reference":"<batch UUID>/observation/<zero-based index>","definition":{…}}`.
It includes every anchor and the full summary/uncertainty, not just a representative
quote. Shared-document findings remain distinct across receipts; no deduplication
or candidate selection erases them. Source disclosure does not grow: the reducer
receives only proposals and quotes from already disclosed records.

The v2 reducer response has exactly the v1 fields plus `observation_refs`.
For a proposal, it must return every supplied observation reference exactly once,
in its chosen review order. It cannot return a changed definition, invent a
cross-batch observation, or hide observations by omitting their scenarios from
`candidate_refs`. Abstention requires empty `families`, `candidate_refs` and
`observation_refs` and publishes no global findings. Earlier batch receipts remain
inspectable but never become a partial global discovery.

Composition copies the exact fixed observation objects locally, including all
quotes and uncertainty. It validates the final result against the complete frozen
sources with `observation_limit: 100 * discovery_receipt_count`. Each provider
discovery still validates against 100, including discoveries in a batch analysis.
The reducer input/request still refuses above 1 MiB, including observations,
instead of dropping content. The transport still limits responses to 100 KiB.
An endpoint must fit all findings within both limits or abstain; the service does
not make a second call to repair output.

## Shared request and review contract

1. `CorpusAnalysis#model?`, `#batch?` and `#observations?` register the fixed v2
   methods beside v1. Defaults and historic method meanings remain unchanged.
2. Explicit `model_observations` and `model_batch_observations` previews/requests
   freeze the selected method, exact source preview, endpoint/model/settings and
   consent. Matching `plan(..., version:)` runs at preview, request and processing
   recheck. V1 plans retain their old shape. Candidate limits, source lifetime,
   document freshness and corpus-purpose approval remain required.
3. The existing once-claimed job and corpus-lock publication transaction handle
   v2. No retries, repair calls, extra discoveries or extra reducers were added.
4. The result view reads `corpus_analysis_result.result["observations"]` only for
   the v2 discovery schema. A reducer abstention has the merge schema and no
   global observations. Legacy rows lack this field; do not call that an empty
   v2 discovery or evidence that no support issue exists.
5. Native disclosures show status, summary, uncertainty and every anchor, with the
   fixed receipt/result and source snapshot identity. Scope references through
   the analysis's fixed inputs, not arbitrary IDs or current replacement records.
   Hide expired content and use existing source deletion/retention gates. Show
   stopped intermediate receipts as receipts, not published global observations.
6. Keep expert decisions separate. Observations cannot create expert associations,
   taxonomy labels, approved scenarios, human labels, eval expectations or training.

`persist!` retains the full array in the existing immutable result inside the
caller's publication transaction. No table or migration is needed. Existing
cluster signals and summary counts keep their v1 meaning; these counts are not
observation quality, coverage or accuracy. No new dependency or live endpoint
appears in this slice.

## Checks and limits

Run the native focused tests:

```sh
PARALLEL_WORKERS=1 bin/rails test test/services/model_corpus_discovery_test.rb test/services/batch_corpus_discovery_test.rb --seed 20261001
bin/rubocop app/services/model_corpus_discovery.rb app/services/batch_corpus_discovery.rb test/services/model_corpus_discovery_test.rb test/services/batch_corpus_discovery_test.rb
```

The authored fixtures exercise contract behavior: exact cross-source anchors,
both sides of bounds, invalid first/middle/last members, retained uncertainty,
asymmetric batch order, observations beyond candidate selection, repeated shared
evidence, aggregate bounds, v1/v2 separation, abstention and no partial publication.
Batch service tests now use native registration and plan selection, without the
worker's temporary substitutes. Integrated request/job/access checks cover single
and batch v2, wrong-version consent, once-only execution, revocation, retained
historical anchors, expiry/purge and v1 results. Browser journeys cover explicit
selection, repair, keyboard consent, all quotes, empty and stopped global results
at desktop/mobile widths. These checks do not establish customer usefulness.

Only sources disclosed together can ground a new observation. The reducer retains
and orders existing findings in v2; it does not create relationships between
records split across discoveries. Explicit
[batch v3](./CROSS_BATCH_RELATIONSHIPS.md) adds proposed relationships over only
retained exact observation anchors while preserving every original and the same
call plan. V1/v2 remain unchanged. The bounds remain explicit refusals, not a claim
to cover every corpus size or unseen relationship. Live model quality, expert
acceptance and the owner's unseen-customer acceptance demo still need separate
evidence. No live disclosure, training, deployment or provider-call increase
occurs here.
