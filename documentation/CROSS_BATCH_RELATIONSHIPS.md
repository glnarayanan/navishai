# Cross-batch support relationships

Decision before code, 1 October 2026. This closes the retained-observation gap in
the original corpus-understanding scope, not live model-quality acceptance.
Authority: [PRODUCT](./PRODUCT.md), [ARCHITECTURE](./ARCHITECTURE.md),
[DOMAIN](./DOMAIN.md) and [the original acceptance map](./REBUILD_ACCEPTANCE.md).

## Fixed contract

Add explicit `model_batch_relationships`, fixed as `support-corpus-batch-v3`.
Discovery still requests `support-corpus-v2`: complete allocated records, every
fixed document, source-backed observations and unchanged scenario candidates.
Use `support-corpus-merge-v3` only for the existing final reducer. Preserve v1/v2
defaults, plans, receipts and meanings. The v3 plan digest binds this choice even
for one batch, which uses no reducer and publishes no cross-batch relationships.

The reducer sees every full fixed v2 observation, summary, uncertainty and anchor.
It must return every observation reference exactly once, independent of candidates.
It may also propose 0–100 relationships, each with only kind, proposed status,
summary, required uncertainty and 2–8 distinct anchor references. Kinds use the
existing support-distinction vocabulary, not a universal company issue taxonomy.
Each anchor names an exact discovery UUID/observation index plus an integer
evidence index. At least two discovery receipts and two distinct source records
must support a relationship; a repeated shared document alone cannot supply it.
Only exact anchors already in the reducer input qualify. The reducer cannot
invent quotes, refer to arbitrary source IDs, change an observation, supply expert
truth or create labels, associations, scenarios or expectations.

Composition copies the complete originals locally and resolves relationship
anchors to their exact source reference/quote, retaining the observation reference
and evidence index. Global v3 results use `support-corpus-global-v3`; per-batch v2
receipts remain unchanged. Validate all relationships before publication. A missing
observation, foreign anchor, malformed field, out-of-bound response, abstention,
revoked authority or unknown outcome publishes no partial global findings.

No calls are added: at most 30 discoveries plus one reducer, each discovery within
100 complete records / 256 KiB; whole fixed inputs within 2000 / 10 MiB; reducer
input/request within 1 MiB and response within 100 KiB. Refuse, never sample/drop,
retry, repair or disclose more source text. Keep corpus-purpose endpoint approval,
exact source/plan consent, fixed settings, document freshness, expiry/purge,
tenant lineage, once-only receipts and existing publication lock/transaction.

## Review and limits

Reuse the native preview and result disclosures. Explain v3 before consent and
show each proposed relationship with uncertainty, every quoted source/snapshot,
and the exact contributing receipt/observation. Originals remain separately
inspectable even if no candidate or relationship uses them. Empty relationships
mean no proposal, not no contradiction or issue. Viewers remain read-only.

This enables new relationships across disclosed batches, but only from retained
observation anchors. It cannot infer an unseen relationship whose evidence was
never retained, prove causal or policy meaning, or guarantee exhaustive coverage.
Quoted provenance is not entailment. Fixtures prove the versioned engineering
contract; useful company taxonomy and relationships need authorized unseen data,
experts and live-quality evidence. No new dependency, training, disclosure purpose,
live provider call, migration or hosting policy follows this slice.

## Done checks

Test an asymmetric relationship between two records that no discovery saw together;
preserve all originals, including unselected and repeated-document findings. Test
foreign/wrong-batch/negative/fractional/out-of-range anchors, one-batch and
one-source impostors, each bound, version mixing, omitted observations, abstention,
revocation, once-only execution, historical sources, expiry/purge and SQL
immutability. Native request tests must bind the v3 plan and preserve repair.
Render and inspect preview/result/empty/stopped states at desktop/mobile widths,
including keyboard disclosure, source links, no overflow and no CSP violation.

## Executed evidence

```sh
DATABASE_URL=postgresql:///navishai_lab_scale80_test PARALLEL_WORKERS=1 \
  bin/rails test test/services/cross_batch_relationships_test.rb \
  test/services/model_corpus_discovery_test.rb test/services/batch_corpus_discovery_test.rb \
  test/integration/support_observations_access_test.rb \
  test/integration/cross_batch_relationships_access_test.rb \
  test/integration/private_logging_test.rb --seed 64405
DATABASE_URL=postgresql:///navishai_lab_browser72_test CHROME_ARGS=--no-sandbox \
  CAPTURE_LAB_SCREENSHOTS=1 PARALLEL_WORKERS=1 bin/rails test \
  test/system/cross_batch_relationships_journey_test.rb \
  test/system/support_observations_journey_test.rb --seed 64405
bin/prove-backup-restore
bin/prove-upgrade
bin/rubocop
bin/rails zeitwerk:check
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit check
bin/importmap audit
```

Focused checks pass 48 tests / 1083 assertions; browser checks pass 4 / 193, with
no failures, errors or skips. Both operations proofs pass/CLEAN with retained v3
history, actual runtime SQL denials, no resend and expiry/purge. Style passes
375 files; eager loading and audits pass; Brakeman reports zero errors/warnings.
Inspected captures include preview, repair, every original, new relationships,
empty and stopped results at 1280/390px plus 320px relationship wrapping.
Named Ponytail/CE tools were unavailable; direct risk review and native checks
found no remaining engineering blocker.

Final combined `DATABASE_URL=postgresql:///navishai_lab_ci81_test
CHROME_ARGS=--no-sandbox BUNDLE_FROZEN=true bin/ci` passes in 17m48.72s:
Rails 640 tests / 10520 assertions and browser 71 / 3561, no failures/errors/skips.
Style, eager loading and all native audits pass. See
[STATUS](./STATUS.md#final-combined-engineering-evidence) for seeds and exact
implementation attribution. [#222](https://github.com/glnarayanan/navishai/pull/222)
is pushed/open above #221, not merged/deployed or live-quality acceptance.
