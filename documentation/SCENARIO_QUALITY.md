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

Use the first sentence of the first nonblank text block, at most 2000 characters, as an explicitly
unreviewed starting-situation proposal rather than the title. This is not a safe
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
Enforce the shared 100-KiB response limit in schema validation too. Raw reason
and quote lengths and requirement statements must satisfy bounds, including surrounding whitespace. Quotes
must be exact substrings of the fixed disclosed excerpt, with exactly one valid
link per requirement. Reject non-string references without raising an accidental
type error. A model scenario proposal must keep the fixed starting situation and
may only retain a typed subset of its known facts; it cannot invent visible facts
or hidden truth. Model corpus discovery retains its own definition contract.
Quotes prove provenance, not entailment or correct company policy. A prompt cannot
prove sound diagnosis, contradictions, entitlement or resolution.

## Controlled variants

Extend the existing named-fact mutation to 1–5 distinct existing known-fact keys.
Values retain JSON types and exact before/after; reject no-ops, unknown keys,
oversize mutation metadata and stale/expired/unapproved parents atomically. One
reason and proposed expected difference describe the controlled set. Retain the
exact parent version and source evidence. This covers coupled variables such as
plan/role/IdP/incident only when experts already supplied those named facts; no
universal product policy or synthetic conversation generator is added.

New variants clear outcomes, actions, prohibitions, escalation, grounding, hidden
facts and follow-ups. They do not copy parent expectations or approval. The author
must revise the starting situation and write fresh source-backed expectations,
then review that version. A proposed difference is never a machine or expert label
by itself. Existing single-variable callers keep their before/after receipt shape.

## Lifecycle and evidence

Use existing same-workspace/corpus foreign keys, immutable scenario-version and
evidence triggers, content-free audit actions, expiry gates and source purge.
The additive notes column uses the existing runtime table grants; no new role or
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
