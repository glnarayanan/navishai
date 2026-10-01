# Scenario draft quality

Decision recorded before code on 1 October 2026. Authority: the owner's rebuild
prompt, [PRODUCT.md](./PRODUCT.md), [ARCHITECTURE.md](./ARCHITECTURE.md) and
[DOMAIN.md](./DOMAIN.md). This slice changes scenario construction, not corpus
selection, disclosure, source intake or expert authority.

## Local construction

The normalised conversation format has title, text and arbitrary context JSON.
Zendesk descriptions/comments and Intercom source/parts join with blank lines;
intake does not retain reliable speaker roles. JSON/JSONL text may contain roles,
HTML or mixed instructions, but mining cannot assume a transcript grammar.

Use the first sentence of the first nonblank text block, at most 2000 characters,
as an unreviewed starting-situation proposal rather than the title. This is not a safe
target prompt until an expert removes answers and private data. Leave known facts,
hidden facts and all five expectation lists empty. Raw context can contain answers,
outcome reports and sensitive account state; inspect it in the full source rather
than copying it into target input. Do not turn historic diagnostic instructions
into required behaviour.

Scan the complete retained text for literal review cues: symptom/issue, diagnosis,
diagnostic progression, conflicting guidance, closure, repeated failure,
entitlement, workaround and escalation. These are review questions, not detected
truth. Retain at most the first and last occurrence per cue (18 spans total),
with exact character offsets and at most 240 quoted characters per span on screen.
Negation, sarcasm, speaker identity, causal support and semantic contradictions
remain expert work. Closure and repeated-failure cues remain distinct; neither
proves false resolution. A diagnosis mention is not proof of a diagnosis.
The listed cues match English words, not other languages or paraphrases. The
opening boundary uses punctuation, not speaker attribution or causal inference.

Keep the existing single expectation excerpt per source/version. For text over
4000 characters, select a contiguous 4000-character window covering the most
distinct cue types, then most retained cue spans, then the earliest offset. Inspect
the full source for omitted cues. Short sources stay complete. No source text is
rewritten or removed. Freeze method, offsets, source length and context-omission
notice in `draft_notes` (JSON object, at most 10 KiB); it contains no copied source
text. Expert revisions retain these original notes, not a new machine decision.
Model-discovery drafts keep their existing source-backed definitions unchanged.

## Structured extraction

Keep `source-scenario-v1` and its separate scenario-purpose endpoint/consent gate.
Enforce the shared 100-KiB response limit in schema validation too. Raw reasons,
quotes and requirement statements must satisfy bounds, including surrounding
whitespace. Quotes must be exact substrings of the fixed disclosed excerpt, with exactly one valid
link per requirement. Reject non-string references without raising an accidental
type error. A model scenario proposal must keep the fixed starting situation and
may only retain a typed subset of its known facts; it cannot invent visible facts
or hidden truth. Model corpus discovery retains its own definition contract.
Quotes prove provenance, not entailment or correct company policy. A prompt cannot
prove sound diagnosis, contradictions, entitlement or resolution.

## Controlled variants

Extend the existing named-fact mutation to 1–5 distinct existing known-fact keys.
Values retain JSON types and exact before/after; reject no-ops, unknown keys,
duplicate JSON keys, oversize mutation metadata and stale/expired/unapproved
parents atomically. One reason and proposed expected difference describe the set. Retain the
exact parent version and source evidence. This covers coupled variables such as
plan/role/IdP/incident only when experts already supplied those named facts; no
universal product policy or synthetic conversation generator is added.

The web editor accepts a JSON object of changed key/value pairs in `mutation`, at
most 10 KiB encoded. The saved receipt contains `changes`, with each variable's
exact before/after, plus reason and proposed difference (1–2000 raw characters
each); the whole receipt and each fact object remain within 10 KiB. Existing
single-variable calls keep their receipt shape. PostgreSQL and Rails freeze the
parent link; revisions keep the same receipt and parent version.

New variants clear outcomes, actions, prohibitions, escalation, grounding, hidden
facts and follow-ups. They do not copy parent expectations or approval. The author
must revise the starting situation and write fresh source-backed expectations,
then review that version. A proposed difference is never a machine or expert label
by itself. Explicitly permitted knowledge stays linked, but the expert must check
that it still applies. The system cannot infer counterfactual policy or causal truth.

## Lifecycle and evidence

Use existing same-workspace/corpus foreign keys, immutable scenario-version and
evidence triggers, content-free audit actions, expiry gates and source purge.
The parent-link trigger reuses the existing immutable-record function. The
additive notes column uses the existing runtime table grants; no new role or
content receipt table is needed. Targets still receive only situation, expert-known
facts and explicitly permitted knowledge; draft notes, mutation, expectation
evidence and hidden facts stay local. No model call, dependency, training or
deployment follows local mining or variant creation.

Non-live checks must use asymmetric source histories, late diagnostics, conflicting
claims, closure followed by failure, mixed raw context and coupled typed mutations.
Test exact source offsets and target exclusions, not scenario counts alone. Check
tenant/SQL lineage, append-only history, expiry/purge, runtime DML and rendered
desktop/mobile review, blocked variant and repair states. These tests prove the
construction contract, not real-company scenario quality or measured coverage.

## Non-live receipts — 1 October 2026

Ruby 4.0.6 and the exact lockfile, including json 2.21.2. Native setup and both
additive migrations ran in this orb. The initial checkout's owner lockfile edit
stays untouched; the implementation uses a separate exact-base worktree.

The following focused command passed: 100 runs, 1868 assertions, no failures,
errors or skips. It includes SQL lineage, version/evidence/parent immutability,
expiry/purge and disposable runtime-role DML proof, plus compiler and connected
HTTP/replay contracts. HTTP/model responses are stubs, not live providers.

```sh
PARALLEL_WORKERS=1 mise exec -- bin/rails test \
  test/services/scenario_quality_test.rb test/services/scenario_extractor_test.rb \
  test/services/model_corpus_discovery_test.rb test/models/scenario_variant_test.rb \
  test/models/scenario_test.rb test/models/scenario_proposal_test.rb \
  test/models/scenario_proposal_delivery_test.rb test/integration/scenario_access_test.rb \
  test/integration/scenario_proposal_access_test.rb test/models/eval_compiler_test.rb \
  test/models/http_evaluation_test.rb test/models/evaluation_delivery_test.rb \
  test/services/http_target_test.rb test/services/http_target_transport_test.rb \
  test/services/http_conversation_target_test.rb test/services/support_lab_acceptance_test.rb \
  test/integration/http_evaluation_access_test.rb
```

Native Chrome system checks passed: 12 runs, 543 assertions, no failures, errors
or skips. The source questions, coupled receipt, JSON repair, blocked approval and
reviewed state ran at 1280 and 390 CSS pixels. Keyboard disclosures, associated
field errors, no horizontal overflow and no CSP violations passed. Source-review,
receipt, repair and blocked-state captures were inspected, not only saved.

```sh
CHROME_BIN=/home/user/.agent-browser/browsers/chrome-154.0.8037.57/chrome \
  CHROME_ARGS='--no-sandbox' CAPTURE_LAB_SCREENSHOTS=1 PARALLEL_WORKERS=1 \
  mise exec -- bin/rails test test/system/scenario_journey_test.rb \
    test/system/scenario_proposal_journey_test.rb test/system/http_evaluation_journey_test.rb \
    test/system/conversation_turns_journey_test.rb
```

`bin/rubocop`: 306 files, no offenses. `bin/bundler-audit` and `bin/importmap audit`:
no vulnerabilities. `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error`:
no warnings/errors. `bin/rails zeitwerk:check`: passed. `git diff --check`: passed.
All native commands used `mise exec --`. Ponytail Audit and CE Code Review were
unavailable; a direct risk review covered the changed contracts and SQL lifecycle.

Shared request/SQL filters now cover `mutation`, draft notes, definitions and
results. The combined schema includes both additive migrations; ARCHITECTURE and
STATUS describe source-review drafts rather than copied facts/actions.
[REBUILD_ACCEPTANCE.md](./REBUILD_ACCEPTANCE.md) records combined checks separately
from the worker counts above. No real company data, model quality, measured coverage,
provider execution, deployment or live acceptance follows these engineering checks.
