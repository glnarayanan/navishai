# Rebuild plan

Authority: [PRODUCT.md](./PRODUCT.md). Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md). Terms: [DOMAIN.md](./DOMAIN.md). This plan replaces every old milestone list; [STATUS.md](./STATUS.md) holds executed evidence.

## Delivery rules

Preserve Git history and user-owned changes. Use small conventional commits and stacked PRs, each based on the preceding slice. Do not merge, release, deploy, train, or disclose customer data without the matching authority. No compatibility flags for the old product. Before each slice, state its goal and done checks; stop expanding that slice when they pass.

## A — Demolition and reset

Write the four authorities before code. Retain auth, tenancy and relevant security controls; prune their domain edges. Remove old routes, pages, models, jobs, tests, migrations, memory, runner/installer ceremony, and stale docs. Replace the database baseline without dropping an existing database in setup. Keep a small honest application shell and current development/CI instructions.

Done: boots with no old product surface; retained security tests pass; eager loading and fresh schema pass; no dangling domain references; desktop/mobile shell inspected. No new eval execution.

## B — Corpus and scenario foundation

Bounded JSON conversation export plus text/Markdown documentation intake; sources, immutable snapshots, corpus items; local analysis with disclosed method; company-specific taxonomy and clusters; bounded representative/high-risk mining; provenance; expert edit/approve/reject/merge/relabel/importance; immutable scenario versions and controlled variants.

Done: unseen asymmetric fixture imports atomically, repeated intake is defined, foreign evidence fails, analysis explains selection, changed versions need review, and variants record exact changes. Browser-test the review journey and inspect empty/error/review states. No suite execution before these pass.

## C — Eval Compiler and calibration

Freeze reviewed versions into suites/cases/contracts. Add deterministic checks first, then versioned rubric judges. Keep evidence for each expectation. Labels bind to frozen outputs and definitions; show measured agreement and disagreement without inventing accuracy. Calibration edits create versions, not rewrites of prior results.

Done: compilation rejects unreviewed/stale versions; checks distinguish required/forbidden actions, collected fields, citations, escalation and missing evidence; asymmetric labelled examples prove confusion counts; foreign definitions fail.

## D — Evaluation and regression

One provider-neutral target interface, scripted proof before live execution, then bounded generic HTTP execution. Freeze run inputs and target settings; retain outputs, per-check outcomes, errors, uncertainty, and usage. Group behavioural failures; let experts add failed cases to a regression suite.

Done: source → review → compile → run → inspect failure → regression passes end to end; a later target passes the corrected case; retries/concurrency do not duplicate results; malformed/timeout/foreign output and private-address targets fail safely. Do not claim live-provider quality from fixtures.

## E — Continuous evaluation (P1)

After the P0 loop works, ingest production traces and human corrections; match or propose new scenarios; create reviewed regressions; flag source-change impact and stale assumptions. Add cross-version comparisons and useful calibration metrics.

Done: a production failure becomes a provenance-backed reviewed regression, and a changed policy identifies affected versions without altering history. No general tracing or prompt-management platform.

## F — Classifier factory (P2, gated)

Only with enough customer labels and evidence of repeated expensive judgments, compare a candidate classifier with the judge on held-out labels and cost. Training, local models, active learning, and deployment require a separate scoped decision. Do not build this phase to make the first demo look complete.

## Final acceptance

Use an unseen B2B SaaS corpus, discover useful company issue families, select representative and risky cases, obtain expert corrections, compile calibrated checks, exercise a support target, explain concrete failures with evidence, and retain regression cases. Record engineering checks, missing quality evidence, external credentials/host limits, delivery state, and the next incomplete slice separately.
