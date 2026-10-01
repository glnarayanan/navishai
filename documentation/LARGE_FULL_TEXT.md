# Larger complete-text local analysis

Decision recorded before code, 1 October 2026. Base: the bounded-mined-labels
rebuild, not the old product on `main`.

## Decision

Add the explicit `local_large_full_text` request and freeze
`tfidf-large-full-text-seed-centroid-selection-v4`. It includes complete titles
and conversation text, with complete documents. Original local remains the default.
It is a local lexical method, not semantic diagnosis or a customer-quality claim.

| Fixed method | Conversation term window | Complete input limits |
|---|---|---|
| Original local, v1 | First 4000 characters plus title | 2000 records / 10 MiB |
| Streaming local, v2 | First 4000 characters plus title | 100,000 records / 1 GiB |
| Full-text local, v3 | Complete text plus title | 2000 records / 10 MiB |
| Large full-text local, v4 | Complete text plus title | 100,000 records / 1 GiB |

Bytes include retained IDs, titles, text and PostgreSQL context JSON. These are
analysis bounds, not new upload limits. Existing results, methods, fixed membership
and historical snapshots stay unchanged. No fallback, truncation or sampling occurs.

Reuse scalar processing in batches of 100, sparse term counts, global document
frequencies over all fixed conversations and ordered seed clustering. Keep the
0.3 cosine threshold, seed-order ties, centroid selection, full-text risk signals,
document-term gaps and exact source provenance. Never cluster batches separately.

Reuse the v2/v3 computation caps: 2 million conversation-term entries, 250,000
distinct terms across conversations and documents, and 2 million seed comparisons.
Count late terms too. Exceeding any cap fails the whole attempt without partial
families, membership, summary or completion audit. A duplicate job cannot retry it.
Recheck writer access and source lifetime after computation before commit.

Requests freeze IDs without loading complete source objects. Processing reads only
the scalar fields it needs; membership writes stay in bounded transaction batches.
Complete evidence reads and mining still accept at most 10 MiB. A blocked overview
keeps read-only fixed-family links for smaller inspection, never partial previews
or write controls. This is not a fixed process-memory ceiling: scalar batches,
tokenization and retained sparse vectors still allocate within the input/work caps.
An otherwise valid corpus may exceed a work cap and need a smaller deliberate request.

The native picker requires an explicit choice, names its input bounds, retains
the choice on refusal and states the older 4000-character windows. Queued,
complete and error pages show the fixed version and limits. Experts still review
taxonomy and source-backed scenario drafts. Complete-text clustering does not
improve mining's bounded excerpts or supply authoritative expectations.

No model configuration, disclosure, customer data, provider call, production
dependency, new schema, service or index follows from this method. Source text
remains untrusted. Model methods and their separate consent stay unchanged.

## Stored lineage and lifetime

V4 reuses `corpus_analyses`, `corpus_analysis_inputs`, `issue_clusters` and
`cluster_members`; it adds no receipt table. Existing composite foreign keys
bind each row to its workspace, corpus, fixed analysis and source item. Existing
SQL triggers freeze method definitions, terminal results and member rows.
Requests and completions use the existing audit actions. Source replacement
cannot alter fixed inputs; expiry blocks reads and processing, and source purge
cascades through analyses, members and mined drafts while retaining audit events.

The existing `db:grant_runtime` task grants the restricted runtime role table DML
and sequence usage. V4 needs no new grant or database privilege. Native tests use
the development/test role; [OPERATIONS_ACCEPTANCE.md](./OPERATIONS_ACCEPTANCE.md)
records separate combined runtime, recovery and container checks.

## Evidence plan

Use authored asymmetric synthetic conversations with shared preambles and distinct
late diagnostics. Exercise real inputs above both 2000 records and 10 MiB, complete
fixed partitions across scalar batches, global weighting, typed reports, rare-risk
priority, source replacement, immutable methods and unapproved historical mining.
Check the actual 100,000/100,001 record edge; test exact UTF-8 byte and work-cap
edges with smaller injected caps rather than allocate 1 GiB only for an assertion.
Refusals must load no complete source objects and save no partial proposals.

Run native focused and broader checks. Render and inspect desktop/390px selected,
complete and error states with keyboard selection, actual viewport-width checks,
no horizontal overflow, intact recovery and no CSP violations. These checks prove
method behaviour and resource refusal, not useful company taxonomy, semantic
quality or customer acceptance.

## Executed evidence, 1 October 2026

The final native focused run passed: 47 tests, 1368 assertions, no failures,
errors or skips. It includes the existing v2 100,000-record test and v4's actual
100,000/100,001 edge, plus retained-method, tenant/SQL, expiry/purge and refusal
checks. The combined run took 9:18.81, with peak RSS of 484180 KiB; this is one
synthetic test run, not a memory guarantee.

```sh
bin/rails test test/models/large_full_text_analysis_test.rb \
  test/services/large_full_text_discovery_test.rb \
  test/integration/large_full_text_access_test.rb \
  test/services/corpus_discovery_test.rb \
  test/services/streaming_corpus_discovery_test.rb \
  test/services/varied_corpus_discovery_test.rb \
  test/integration/corpus_access_test.rb \
  test/integration/corpus_exploration_test.rb
```

With the installed Chrome/driver configured, the native browser run passed:
5 tests, 326 assertions, no failures, errors or skips. Keyboard submission and
fixed-family recovery ran in the browser. Actual widths of 1280 and 390, 2× pixel
ratio, horizontal overflow and CSP checks passed. All ten final screenshots were
inspected: selected, queued, complete, budget error and blocked evidence at both
widths. The shorter v4 picker label fits mobile; full limits remain in the help.

```sh
CAPTURE_LAB_SCREENSHOTS=1 PARALLEL_WORKERS=1 bin/rails test \
  test/system/large_full_text_journey_test.rb \
  test/system/streaming_discovery_journey_test.rb
```

Review images live under `.amp/in/artifacts/large-full-text/`, outside Git.
Earlier runs caught test-only selector, label-order and expired-session assertions;
the final runs above include their fixes. A command with nonexistent test paths
stopped before loading tests; the corrected focused command appears above.

Other native checks passed: `bin/rubocop` (306 files, no offenses),
`bin/rails zeitwerk:check`, `git diff --check`, `bin/bundler-audit`,
`bin/importmap audit` and `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error`
(no warnings). Setup used the locked `json` 2.21.2 with Ruby 4.0.6. Lockfile
changes are outside this slice. The focused manual review checked method dispatch,
scalar/global weighting, atomic commit, fixed lineage and bounded evidence reads.
Ponytail Audit and CE Code Review tools were unavailable in this thread.

[REBUILD_ACCEPTANCE.md](./REBUILD_ACCEPTANCE.md) records combined CI and delivery,
separate from the worker counts above. No customer data or provider call was used;
these fixtures do not show semantic or customer quality.
