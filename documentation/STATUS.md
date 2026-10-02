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
- [#147](https://github.com/glnarayanan/navishai/pull/147), based on #146: fixed output samples, authoritative expert
  label history, held-out/development reports and measured disagreement.
- [#148](https://github.com/glnarayanan/navishai/pull/148), based on #147: scripted targets, fixed runs/results,
  explained failures and human-reviewed regression admissions.
- [#149](https://github.com/glnarayanan/navishai/pull/149), based on #148: generic HTTPS targets, per-workspace
  operator approval, human disclosure confirmation and bounded non-retrying calls.
- [#150](https://github.com/glnarayanan/navishai/pull/150), based on #149: fixed rubric judges, separate
  disclosure consent, once-claimed calibration attempts and quoted result evidence.
- [#151](https://github.com/glnarayanan/navishai/pull/151), based on #150: prevent stale HTTP-only consent
  from sending cases added after review.
- `rebuild/12-p0-workflow-proof`, based on #151: fresh technical-Support fixture
  through the whole engineering loop, including held-out calibration and replay.

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
scripted/HTTP evaluation, rubric judge execution and regression are built.
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

Scripted evaluation `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 1m39.48s;
190 Ruby files clean, gem/importmap audits clean, Brakeman zero warnings/errors,
eager load passes. 182 Rails tests / 1359 assertions and 8 browser tests / 224
assertions, no failures/errors/skips. Focused tests distinguish first matching
rules, null/false/absent facts, fixed target/input/membership, missing judge abstention,
schema errors, access/approval/expiry changes, partial worker failures, concurrent
delivery (one actual target call), immutable Ruby/SQL records, foreign/mismatched
links, the 100-check bound, purge, and regression → corrected target on the same case.
Browser checks exercise retained JSON errors, queued refresh, evidence-backed
failures, human admission and fixed older results after a later target passes.
Desktop/mobile failure, regression, pass and error captures were inspected; native
controls have clear prompts, no horizontal overflow or CSP violations. The detector
reported no new issues. Direct risk review covered disclosure, claims, immutability
and deletion. Stale target forms retain their original version token. Full CI first
exposed committed test-corpus/audit pollution from the concurrent-delivery test;
its teardown now removes its own records without changing production controls.
Final focused browser check: 1 test / 43 assertions. The expanded source-deletion
warning and updated home copy were also rendered and inspected on mobile.

HTTP target `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 1m45.34s;
198 Ruby files clean, gem/importmap audits clean, Brakeman zero warnings/errors,
eager load passes. 194 Rails tests / 1540 assertions and 9 browser tests / 277
assertions, no failures/errors/skips. Real local TLS checks cover a trusted stream,
wrong hostname and redirect refusal; unit checks cover exact workspace/URL approval,
credential isolation, mixed/private/translated DNS, address pinning, no proxy/retry,
input/stream bounds, bad encoding/schema, DNS-inclusive deadline and unknown outcome.
Run tests prove separate disclosure confirmation, frozen visible-only inputs,
immutable UUID/metadata, operator revocation, no duplicate delivery, no regression
from execution errors and discarded output after changed approval/evidence. A
two-case concurrent test acquires corpus/membership locks during the network wait,
expires a source and proves no retained response or second call. No external target
ran. Browser checks cover retained HTTP form errors, disclosure blocking and unknown
results on desktop/mobile without overflow/CSP violations. Captures were inspected;
the prior-attempt notice now says the run did not start. The detector reported only
existing Geist font warnings; the lab's visual system remains unchanged. Compose
and orb service YAML parse; this is not a clean-host deployment check. Direct risk
review/native audits replace unavailable Ponytail Audit and CE Code Review. Early
focused failures came from test helper binding/scope and an unsupported browser
assertion; corrections did not weaken product controls.
Final focused browser check: 1 test / 50 assertions, including Space-key disclosure
confirmation, no failures/errors/skips. No product code changed after full CI.

Judge execution `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 1m55.86s;
209 Ruby files clean, gem/importmap audits clean, Brakeman zero warnings/errors,
eager load passes. 208 Rails tests / 1708 assertions and 10 browser tests / 349
assertions, no failures/errors/skips. Fixed definitions bind the endpoint, model,
settings, rubric and threshold. Target and judge calls share the bounded approved
transport; judge consent remains separate. Suite consent binds the displayed case
IDs. Calibration retains one immutable attempt/prediction per sample and never
overwrites human labels. Inputs omit hidden facts, labels and other predictions.
Pass/fail responses need exact quotes from company evidence and recorded output;
low confidence abstains. Quotes and self-reported confidence do not prove accuracy.
Usage/cost remain optional endpoint reports, not verified charges.

Checks cover separate consent, stale suite membership, threshold boundaries,
malformed/model/quote/cost rejection, fixed graders after revision, SQL immutability,
purge, role/endpoint revocation, unknown outcomes and concurrent delivery/expiry.
Network waits do not hold corpus/membership locks. Browser checks cover retained
configuration errors, first-label hiding, consent, queued refresh and quoted failure
inspection, without overflow/CSP violations. Nine desktop/mobile judge captures
under `.amp/in/artifacts/judge/` were inspected. The detector found no new issues;
direct risk review and native audits replace unavailable Ponytail Audit and CE Code
Review. Early failures came from foreign-key/last-Owner test setup and a browser
selector; fixes did not weaken those controls. Orb YAML and `git diff --check` pass.
No live judge or target ran. The operator endpoint registry remains empty.

HTTP-only consent review found and reproduced a missing case-list check: without
configured judges, a stale form could queue an added Entra case. The same digest
check now covers every external run. Missing/stale tokens queue nothing; the
refreshed form clears approval and shows the current cases and endpoint. Browser
re-confirmation sends exactly the two reviewed inputs once each. The final
`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 2m3.96s: 209 Rails tests / 1720
assertions and 11 browser tests / 370 assertions, no failures/errors/skips. Ruby
style, gem/importmap audits, Brakeman and eager loading pass. Full CI first exposed
an old integration request that omitted the new required token; the test now sends
the form token. Desktop/mobile stale-consent captures were inspected, with readable
recovery controls and no overflow/CSP violations. Direct risk review/native audits
used; no external request ran. No dependency or schema changed.

P0 engineering proof `bin/ci`: passed in 2m4.17s; 210 Ruby files clean,
gem/importmap audits clean, Brakeman zero warnings/errors and eager loading passes.
210 Rails tests / 1765 assertions and 11 browser tests / 370 assertions, no
failures/errors/skips. One fresh fixture follows raw conversation/document intake
through two issue families, risk selection, expert taxonomy/scenario correction,
source-backed compilation, mixed deterministic/judge checks, held-out labels,
HTTP execution, human regression admission and a later target passing the same
case. A deliberate missed failure yields one true positive, one true negative and
one false negative; the report does not hide it. Duplicate job delivery produces
exactly seven fixture calls, each with its own attempt key. Hidden facts stay
local. Changed policy evidence blocks future runs without rewriting prior results.
This tests the connected pipeline, not live-model accuracy or discovery quality.
No product code changed in this proof slice; direct risk review checked independent
expected inputs, imperfect judge predictions, fixed provenance and call counts.

## Next and limits

The P0 engineering loop passes with fixtures. Next: customer acceptance with a
privacy-approved, previously unseen technical-Support dataset,
authoritative expert corrections and approved target/judge endpoints.
The endpoint registry has no configured entries. Analysis remains bounded to
2000 records and 10 MiB. Scenario mining is a title/context/sentence baseline, not model-based
semantic extraction. Experts supply source-backed outcomes. Controlled variants
need an expert revision before approval. Changed documents flag stale evidence;
new snapshots replace evidence only in new versions. Source purge deletes scenarios
and descendants because their analysis depends on the full corpus. Purge also
clears fixed cases, corpus graders/calibration, targets, runs/results and regressions;
suite names remain without cases. Judges execute through a generic gateway;
the gateway must enforce model/settings and separate data from instructions.
Fixture responses do not establish grader accuracy.
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
