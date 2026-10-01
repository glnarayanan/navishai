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
