# Rebuild status

Updated 30 September 2026. [PRODUCT.md](./PRODUCT.md) replaces the old helpdesk
milestones. The rebuild is not complete. Nothing has merged, released or deployed.

## Delivered stack

- [#141](https://github.com/glnarayanan/navishai/pull/141): product, architecture,
  domain and rebuild authorities, written before new domain code.
- [#142](https://github.com/glnarayanan/navishai/pull/142), based on #141: Phase A
  demolition. Removed 820 tracked files, about 135,000 lines, including helpdesk,
  messaging, SLAs, CS workflows, crews, Supermemory, process runner, obsolete tests,
  installers and docs. Kept auth, workspace access, audit and relevant security.
- [#143](https://github.com/glnarayanan/navishai/pull/143), based on #142: first Phase B slice. Corpus intake,
  snapshots, source evidence, pagination, email masking, retention and deletion.
- [#144](https://github.com/glnarayanan/navishai/pull/144), based on #143: frozen local analysis, term clusters,
  risk-prioritised candidate selection and immutable expert taxonomy revisions.
- [#145](https://github.com/glnarayanan/navishai/pull/145), based on #144: scenario mining, source-backed expert
  edits/review/merge, fixed versions, document knowledge and controlled variants.
- [#146](https://github.com/glnarayanan/navishai/pull/146), based on #145: fixed contracts, exact check/evidence
  bindings, versioned deterministic/rubric definitions and bounded suite membership.
- `rebuild/07-calibration`, based on #146: fixed output samples, authoritative expert
  label history, held-out/development reports and measured disagreement.

## Built and checked

Rails/Hotwire/PostgreSQL with native jobs, local fonts and no new production
dependency. Fresh lab databases leave the old development/test databases alone.
Preflight rejects old names and old-domain tables; setup refuses reset. Local
auth, verification/reset, invitations, OIDC, first Owner, break-glass, last-Owner
locking, CSP, headers, log filters and append-only audit remain. No PostgreSQL RLS.

Bounded JSON conversation exports and text/Markdown intake retain input digest,
processing/redaction version and fixed records. Repeat uploads reuse a snapshot;
changed uploads add one. Composite foreign keys prevent foreign-workspace/corpus
links. Local term analysis, expert labels, versioned scenarios, controlled variants,
fixed eval definitions, deterministic checks and expert calibration are built;
evaluation execution is not built yet.
Expiry hides source content immediately; an hourly job deletes snapshots/items.
Managing roles can delete sources with typed confirmation. Audit retains no source
content. Email masking is not complete PII removal; original files are not kept.

- Phase A `bin/ci`: 120 Rails tests / 642 assertions; 2 browser tests / 49 assertions.
- Corpus `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 48.01s; RuboCop 119 files
  clean; gem/importmap audits clean; Brakeman 0 warnings/errors; eager load passes;
  129 Rails tests / 758 assertions; 3 browser tests / 66 assertions; no failures,
  errors or skips. An exact Phase A association-list test initially failed and now
  checks absence of obsolete associations without blocking new domain records.
- Intake tests cover changed/repeated versions, redaction choices and email IDs,
  both supported vendor shapes, malformed/oversize/partial batches, foreign links,
  viewers, immutable updates, escaping and deletion/expiry. Desktop/mobile source
  and error captures under `.amp/in/artifacts/corpus/` were inspected; expanded
  captures confirm both records and all recovery controls. No horizontal overflow
  or CSP violations. `git diff --check` passes.
- Direct risk-based review used; Ponytail Audit and CE Code Review are unavailable.
- Local discovery `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 53.05s; 132 Ruby files clean, audits clean,
  Brakeman zero warnings/errors, eager load passes; 134 Rails tests / 791 assertions
  and 4 browser tests / 84 assertions, no failures/errors/skips. Tests distinguish
  related company terms from unrelated families, minority critical risk from
  volume, frozen inputs from later imports, human revisions from proposals,
  duplicate jobs, expired input and revoked access. A Rails association deletion
  default initially tried to null a required corpus ID; the purge now uses explicit
  SQL deletion. Desktop/mobile taxonomy captures inspected.
- Scenario `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 58.98s; 143 Ruby files
  clean, audits clean, Brakeman zero warnings/errors and eager load passes. 142 Rails
  tests / 883 assertions and 5 browser tests / 111 assertions, no failures/errors/skips.
  Checks cover stale edits/reviews, unchanged saves, approval gates, merge rules,
  exact-source/foreign evidence, variant provenance, immutable updates, document
  refresh, expiry and deletion. Browser journey covers review, knowledge attachment,
  variant creation, blocked approval and prior versions, with no overflow/CSP issues.
  Full desktop/mobile review and blocked/variant captures inspected. Earlier tests
  exposed an expired test session and an asynchronous stale-form click; neither
  required weakening the product guards. Impeccable found only the established
  Geist/Geist Mono font warnings; retained the pinned local design rather than
  changing the product identity. Direct risk review and native audits used.
- Compiler `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 1m10.69s; 161 Ruby files
  clean, gem/importmap audits clean, Brakeman zero warnings/errors and eager load
  passes. 158 Rails tests / 1087 assertions and 6 browser tests / 150 assertions,
  no failures/errors/skips. Tests cover omitted/duplicate/malformed mappings,
  the 100-statement and 50-case boundaries, repeated compilation, fixed older
  graders, foreign and wrong-version evidence, revoked/current approval, immutable
  SQL updates, expiry/purge, trace schemas, false/zero fields, ordered tools,
  user-only text and exact knowledge citations. Browser journey covers grader
  creation/error/revision, compilation, target-input preview, suite membership
  and rejected-scenario blocking, with no overflow/CSP issues. Inspected desktop/
  mobile contract and mapping captures plus error/blocked states. Early checks
  exposed two fixture expectations and Rails' unpermitted missing-parameter
  fallback; corrected them without weakening coverage or approval guards.
- Calibration `bin/ci`: passed in 1m23.26s; 172 Ruby files clean, audits clean,
  Brakeman zero warnings/errors and eager load passes. 167 Rails tests / 1184
  assertions and 7 browser tests / 185 assertions, no failures/errors/skips.
  Asymmetric counts distinguish false alarms from missed failures; checks cover
  cohort separation, JSON key-order deduplication, disputed/uncertain labels,
  missing/abstaining predictions, fixed graders, stale labels, foreign links,
  SQL immutability, the 100-sample bound and expiry/purge. Browser journey proves
  first-label hiding, correction/history, measured disagreement and empty cohorts.
  Final focused capture check: 1 test / 35 assertions. Desktop/mobile review,
  report, blind and upload-error captures inspected, without overflow/CSP issues.
  Fixed a permitted-parameter conversion error, shortened clipped select labels,
  and corrected full-page capture width rather than changing the app layout.
  Impeccable detector found no new issues; direct risk review and native audits used.

## Next and limits

Next: generic target/judge execution, failure inspection and
regressions. Scenario mining is a title/context/sentence baseline, not model-based
semantic extraction. Experts supply source-backed outcomes. Controlled variants
need an expert revision before approval. Changed documents flag stale evidence;
new snapshots replace evidence only in new versions. Source purge deletes scenarios
and descendants because their analysis depends on the full corpus. Purge also
clears fixed cases and corpus graders; suite names remain without cases. Judge
definitions are versioned but do not yet execute or establish grader accuracy.
Continuous-learning P1 follows a proved P0 loop; classifiers remain gated by labels
and economics. Fixture checks do not establish discovery quality or judge accuracy.

No real customer dataset, live model/target, SMTP/OIDC provider, training or customer
validation ran. Clean-host/Compose image/TLS/backup/restore acceptance is unverified.
Current Compose PostgreSQL tag is not digest-pinned. Database administrators can
bypass triggers; last-Owner protection is application-side. Backups need their own
retention policy. See [development](./DEVELOPMENT.md), [security](./SECURITY.md),
[deployment](./DEPLOYMENT.md) and [design](./DESIGN.md).

The user-owned Bundler checksum in Gemfile.lock remains unstaged and outside the
rebuild commits. Phase A removed obsolete gems and capped JSON below 3 after tests
proved JSON 3 incompatible with this Rails version. No new dependency was added.
