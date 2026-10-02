# Rebuild status

Updated 1 October 2026. [PRODUCT.md](./PRODUCT.md) replaces the old helpdesk
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
- [#152](https://github.com/glnarayanan/navishai/pull/152), based on #151: fresh technical-Support fixture
  through the whole engineering loop, including held-out calibration and replay.
- [#153](https://github.com/glnarayanan/navishai/pull/153), based on #152: bounded production-trace intake,
  immutable reports and source-backed proposals that require expert expectations.
- [#154](https://github.com/glnarayanan/navishai/pull/154), based on #153: exact-input-compatible recorded
  targets, fixed replay results and human failure-to-regression admission.
- [#155](https://github.com/glnarayanan/navishai/pull/155), based on #154: source-backed change impact and
  saved-run comparisons that retain exact case/input identity.
- [#156](https://github.com/glnarayanan/navishai/pull/156), based on #155: local literal corpus search,
  source filters, retained context and exact paginated provenance.
- [#157](https://github.com/glnarayanan/navishai/pull/157), based on #156: personal expert review focus,
  exact calibration provenance and native corpus exploration navigation.
- [#158](https://github.com/glnarayanan/navishai/pull/158), based on #157: isolated synthetic backup/restore proof.
- [#159](https://github.com/glnarayanan/navishai/pull/159), based on #158: fixed source-backed model proposals,
  separate source-processing approval and the corpus navigation regression fix.
- [#160](https://github.com/glnarayanan/navishai/pull/160), based on #159: fixed model corpus discovery,
  complete source disclosure, source-backed families/scenarios and connected proof.
- [#161](https://github.com/glnarayanan/navishai/pull/161), based on #160: pinned PostgreSQL index, private/generated
  build-context exclusions and exact runtime-directory markers.
- [#162](https://github.com/glnarayanan/navishai/pull/162), based on #161: frozen multi-request corpus discovery,
  once-only receipts, strict proposal reduction and explicit allocation/call consent.
- [#163](https://github.com/glnarayanan/navishai/pull/163), based on #162: bounded local failure candidates,
  exact fact/evidence comparisons and append-only expert association history.
- [#164](https://github.com/glnarayanan/navishai/pull/164), based on #163: separate preparation/runtime
  database roles, explicit schema preparation and disposable production-runtime proof.
- [#165](https://github.com/glnarayanan/navishai/pull/165), based on #164: bounded retained-source download,
  exact normalized history and private-copy warnings.
- [#166](https://github.com/glnarayanan/navishai/pull/166), based on #165: saved-result calibration intake,
  fixed provenance, explicit cohorts and blind first-label review.
- [#167](https://github.com/glnarayanan/navishai/pull/167), based on #166: response-scoped v2 transcript checks,
  source-backed failure/regression and separate calibration proof.
- [#168](https://github.com/glnarayanan/navishai/pull/168), based on #167,
  `rebuild/28-calibration-trials` at [`9768637`](https://github.com/glnarayanan/navishai/commit/9768637): local revised-grader development
  previews, separate matrices and held-out/first-label guards.
- [#169](https://github.com/glnarayanan/navishai/pull/169), based on #168: partial
  Compose evidence, actual CI state and clean-host proof limits.
- [#170](https://github.com/glnarayanan/navishai/pull/170), based on #169: bounded incremental HTTP
  conversations, expert plans, conditional disclosure and fixed turn receipts.
- [#171](https://github.com/glnarayanan/navishai/pull/171), based on #170: connected revised-judge
  calibration and restored conversation/no-resend proof.
- [#172](https://github.com/glnarayanan/navishai/pull/172), based on #171: repeatable private-namespace
  Compose preparation/runtime, published ingress and control/edge proof.
- [#173](https://github.com/glnarayanan/navishai/pull/173), based on #172: matched-trace evidence
  revision, fresh expert review/compilation and fixed-case regression proof.
- [#174](https://github.com/glnarayanan/navishai/pull/174), based on #173: complete fixed-family source counts,
  filtered exploration and historical provenance without new judgments.
- [#175](https://github.com/glnarayanan/navishai/pull/175), based on #174: optional fixed human error costs,
  exact observed totals and unchanged calibration history.
- [#176](https://github.com/glnarayanan/navishai/pull/176), based on #175: report-local fixed judge
  abstention rules without tuning or changing predictions/labels.
- [#177](https://github.com/glnarayanan/navishai/pull/177), based on #176: pre-load complete-record
  bounds for current and fixed analysis, with read-only blocked-state recovery.
- [#178](https://github.com/glnarayanan/navishai/pull/178), based on #177: fixed-family selection
  review, whole-analysis counts and read-only focus/pagination.
- [#179](https://github.com/glnarayanan/navishai/pull/179), based on #178: local corpus/source-impact
  pagination that cannot interpret query data as routing authority.
- [#180](https://github.com/glnarayanan/navishai/pull/180), based on #179: expert nomination of one
  fixed record into a local unapproved draft, without changing analysis selection.
- [#181](https://github.com/glnarayanan/navishai/pull/181), based on #180: complete fixed-case
  replay matching with retained-input comparison and read-only per-trace pages.
- [#182](https://github.com/glnarayanan/navishai/pull/182), based on #181: atomic refusal of masking
  collisions and processing-version-aware source snapshot identity.
- [#183](https://github.com/glnarayanan/navishai/pull/183), based on #182: named search bind and shared
  Rails request/SQL-debug private-field filtering.
- [#184](https://github.com/glnarayanan/navishai/pull/184), based on #183: opt-in exact-text masking,
  fixed rule fingerprints and private recovery without rewriting history.
- [#185](https://github.com/glnarayanan/navishai/pull/185), based on #184: bounded fixed-record reads,
  typed family counts and complete-text scalar batches without full-corpus loading.
- [#186](https://github.com/glnarayanan/navishai/pull/186), based on #185: scalar local processing,
  global frequencies, sparse seed lookup and bounded bulk membership writes.
- [#187](https://github.com/glnarayanan/navishai/pull/187), based on #186: explicit larger-local method,
  resource budgets, 100,000-record proof and bounded evidence-page recovery.
- [#188](https://github.com/glnarayanan/navishai/pull/188)–[#191](https://github.com/glnarayanan/navishai/pull/191),
  each based on its predecessor: bounded source writes/download preflight, varied
  local proof and streamed conversation intake.
- [#192](https://github.com/glnarayanan/navishai/pull/192)–[#194](https://github.com/glnarayanan/navishai/pull/194),
  each based on its predecessor: matching count/byte/read preflight and typed mutations.
- [#195](https://github.com/glnarayanan/navishai/pull/195)–[#198](https://github.com/glnarayanan/navishai/pull/198),
  each based on its predecessor: authored retrieval evidence, complete calibration
  accounting, explicit expert selection and typed nested matching facts.
- [#199](https://github.com/glnarayanan/navishai/pull/199)–[#201](https://github.com/glnarayanan/navishai/pull/201),
  each based on its predecessor: varied 100,000-input proof, exact ID lookup and
  skipping irrelevant fact tokenization.
- [#202](https://github.com/glnarayanan/navishai/pull/202), based on #201: private current-scenario
  lookup with exact counts, bounded metadata and native repair/paging.
- [#203](https://github.com/glnarayanan/navishai/pull/203), based on #202: bounded local document
  selection beyond the initial picker window, with private repair and expert review.
- [#204](https://github.com/glnarayanan/navishai/pull/204), based on #203: corpus-relative literal
  ranking with inspectable term contributions, unchanged limits and human authority.
- [#205](https://github.com/glnarayanan/navishai/pull/205), based on #204: explicit complete-text
  local discovery within existing bounds, with fixed older methods and human review.
- [#206](https://github.com/glnarayanan/navishai/pull/206), based on #205: expert replacement of
  fixed historical conversation quotes, hidden from targets and needing fresh review.
- [#207](https://github.com/glnarayanan/navishai/pull/207), based on #206: bounded new draft labels,
  inspectable full proposals and unchanged source evidence/expert decisions.
- [#209](https://github.com/glnarayanan/navishai/pull/209), based on #207: private request/SQL bind
  filters for definitions and receipts, without changing stored company text.
- [#210](https://github.com/glnarayanan/navishai/pull/210), based on #209: original sections
  0–25 and A–F/P0–P2 mapped to exact-base evidence and remaining requirements.
- `rebuild/70-support-eval-landing`, based on #210: technical-Support evaluation
  landing, truthful examples/privacy limits and native responsive/auth checks.

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

Production-trace intake `bin/ci`: passed in 2m5.70s; 215 Ruby files clean,
gem/importmap audits clean, Brakeman zero warnings/errors and eager loading passes.
218 Rails tests / 1929 assertions and 12 browser tests / 405 assertions, no
failures/errors/skips. Checks cover exact schemas and byte limits, malformed and
partial batches, redaction expansion, retained versions, empty reports, approval
gates, repeat proposals, access/expiry, trace exclusion from term discovery and
purge of proposals with no analysis parent. The browser journey imports a fixture,
blocks premature approval, then records an expert correction and fixed approval.
Desktop/390px source and blocked/reviewed captures were inspected; no page
overflow or CSP violations. Native single-line inputs scroll long values; full
titles remain visible in headings. Imported source reports retain their original
unreviewed wording after approval of a separate scenario version. Early checks
found an input-key ordering error; fixed it. Two independent test commands shared
the test database and deadlocked on fixtures; sequential checks and full native CI
pass. Direct risk review/native audits replace unavailable Ponytail Audit and CE
Code Review. No provider call or customer data was used.

Recorded replay `bin/ci`: passed in 2m15.53s; 221 Ruby files clean, gem/importmap
audits clean, Brakeman zero warnings/errors and eager loading passes. 226 Rails
tests / 2011 assertions and 13 browser tests / 456 assertions, no failures/errors/
skips. A fresh trace proposal receives fixture expert expectations and approval,
compiles source-backed checks, fails recorded replay, enters a reviewed regression,
then passes the same fixed case against a corrected scripted target. Input changes
refuse to queue; false, zero, missing facts and changed knowledge references differ.
Old traces/runs stay fixed after new snapshots. Foreign trace IDs, SQL rebinds,
wrong sources, expiry and purge fail safely. Configured judges still need separate
consent and a current case-list token. Imported failure text cannot override a pass.
Checks found a cached source expiry; replay now reloads current retention state.
One test read a stale association after purge; fresh database checks confirm removal.
The browser proves exact-input case inspection, retained target errors, fixed
definition/provenance, replay failures and expert admission. Seven desktop/390px
captures were inspected with no page overflow or CSP violations. Impeccable found
no new issues. Direct risk review/native audits used; Ponytail Audit and CE Code
Review unavailable. No live agent, judge or customer data was used.

Source impact/comparison `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 2m31.37s;
225 Ruby files clean, gem/importmap audits clean, Brakeman zero warnings/errors
and eager loading passes. 242 Rails tests / 2265 assertions and 14 browser tests /
515 assertions, no failures/errors/skips. Checks cover exact snapshots and deduped
evidence, all-source historical/current dependencies, unchanged records after policy
refresh, foreign/expired reads, independent 50-record pagination, both comparison
directions, changed graders/inputs, object ordering, missing/null/false/zero,
unknown outcomes and older baselines outside the 100-run picker. GET comparisons
queue nothing and write no records. Viewers can inspect them, not execute runs.
The browser submits the comparison with Enter, preserves it on refresh and follows
stale policy links. Seven desktop/390px captures were inspected. One scoped CSS
pass aligned dependency columns and reduced mobile comparison spacing; final
captures confirm the fix with no overflow or CSP violations. The first browser
check used a shortened fixture title; corrected the expectation, not product data.
Impeccable found no new issues. Direct risk review/native audits used; Ponytail
Audit and CE Code Review remain unavailable. No provider call, dependency or
schema change. GitHub CI for #153 and #154 also passed.

Corpus exploration `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 2m36.33s;
227 Ruby files clean, gem/importmap audits clean, Brakeman zero warnings/errors
and eager loading passes. 248 Rails tests / 2375 assertions and 15 browser tests /
555 assertions, no failures/errors/skips. Search tests distinguish title, ID, text
and context, Unicode/case, literal wildcards, redaction, current/expired/foreign
sources, query bounds and record-51 provenance. Viewer search writes/queues nothing;
phrases are filtered from Rails parameters/path logs, not browser history.
The browser uses Enter, narrows a source, opens retained context, follows an exact
snapshot/record and recovers from empty/invalid searches. Four desktop/390px captures
were inspected; DOM checks show no page overflow or CSP violations. The final links
reuse the existing provenance helper rather than adding a redirect route.
Impeccable found no new issues; direct risk review/native audits used. No schema,
provider or dependency change. Ponytail Audit and CE Code Review remain unavailable.
GitHub CI on #155 passed the Rails checks but failed an existing calibration browser
test that navigated before label-save completion. A separate test fix now waits for
the saved-label notice; the full local checks above include it. GitHub CI for #156
passed; the earlier failed #155 run remains failed.

Calibration review `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 2m18.57s;
228 Ruby files clean, gem/importmap audits clean, Brakeman zero warnings/errors
and eager loading passes. 252 Rails tests / 2433 assertions and 16 browser tests /
606 assertions, no failures/errors/skips. The queue uses latest expert labels,
keeps first-label states blind, distinguishes disputes/uncertainty/disagreement
from missing predictions and reflects appended corrections. Cohort filters never
narrow report denominators; read-only requests write/queue nothing. Viewers retain
the sample list without review controls. The browser filters with Enter, retains
the filter on refresh, opens a blind next review, saves one human label and recovers
from an empty focus. Four desktop/390px captures were inspected, with no page
overflow or CSP violations. Impeccable found no new issues. Direct risk review/native
audits used; Ponytail Audit and CE Code Review remain unavailable.

Separate fixes reuse exact source/snapshot/record provenance for calibration and
make the same-page corpus jump native. An asymmetric evidence-link test failed
before the snapshot fix. Full CI then caught Turbo clearing a fast search phrase
during its same-page reload; a focused browser check now proves the jump fetches
nothing and preserves Enter search. Both regressions failed before their fixes and
pass in the final full checks above. No schema, provider, training or dependency
change; no real data or live endpoint ran.

GitHub CI for #157 passed in 2m39s
([run](https://github.com/glnarayanan/navishai/actions/runs/36796393741));
the earlier failed #155 run remains failed.

`bin/prove-backup-restore` passed locally with exact table fingerprints, recorded
failure/corrected success on one fixed case, trace/approval provenance, held-out
label history, SQL immutability, workspace/corpus foreign keys and append-only
audit. It removed only its two unique disposable databases and private archive;
existing lab and legacy databases were untouched. This proof omits production
roles/ACLs, separate queue/cache/cable databases, backup retention, PITR, image
builds, TLS and clean-host acceptance. See [deployment](./DEPLOYMENT.md).
The operations slice's `bin/ci` passed in 2m12.80s: 252 Rails tests / 2433
assertions and 16 browser tests / 606 assertions, no failures/errors/skips;
style, native security audits and eager loading passed. The proof script's focused
RuboCop check passed too. Direct risk review found no new dependency or disclosure;
Ponytail Audit and CE Code Review remain unavailable.

GitHub CI for #158 failed an existing corpus-search browser test
([run](https://github.com/glnarayanan/navishai/actions/runs/36797709490)).
A controlled pending-response test reproduced Turbo replacing a phrase typed into
a cached preview. Corpus pages now disable those previews; the regression passes.
That older remote run remains failed; the fix belongs to the next stacked slice.

Source-backed model proposals `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 3m21.03s:
240 Ruby files clean, native audits clean, Brakeman zero warnings/errors and eager
loading passed; 264 Rails tests / 2557 assertions and 19 browser tests / 682
assertions, no failures/errors/skips. Checks cover exact purpose/consent, frozen
input/settings, once-claimed and concurrent delivery, post-request evidence and
expert edits, source/access/endpoint revocation, strict schemas/quotes, unknown
outcomes, immutable SQL records, foreign links and purge. Suggestions never change
scenarios, approval or labels. Desktop/390px proposal, disclosure, queued, abstain
and error captures were inspected; browser checks found no overflow or CSP errors.
The backup/restore proof and its focused RuboCop check passed against the new
schema too; both provider registries stay empty in that proof. Direct risk review
and native audits used; no live model, customer data or new dependency.

GitHub CI for #159 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36799951558)).
The earlier failed #155 and #158 runs remain failed, not retroactively green.

Model corpus discovery `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 3m16.36s:
249 Ruby files clean, native audits clean, Brakeman zero warnings/errors and eager
loading passed; 278 Rails tests / 2729 assertions and 21 browser tests / 763
assertions, no failures/errors/skips. Checks cover separate purpose/consent,
changed preview, fixed historic inputs, byte/record bounds, complete partitions,
exact requirement quotes, source windows, malformed/model/cost rejection,
abstention, authority/expiry/document changes, concurrent delivery/purge,
immutable SQL records, foreign reads and viewer restrictions. The connected
model fixture reaches expert taxonomy/expectation correction, mixed checks,
held-out labels, a deliberately missed failure, HTTP failure and the same fixed
case passing its later regression. Eight distinct fixture requests occur once
despite duplicate delivery. Hidden facts stay local; targets receive no expectations.

The browser checks malformed JSON retention, keyboard consent, exact preview,
queued refresh, human taxonomy review and unapproved scenario mining. Nine final
desktop/390px captures were inspected without overflow or CSP failures. The first
pass found a misleading completion heading and unclear blocked-consent notice;
final captures distinguish the outcome from attempt completion and say the prior
request did not start. The bounded independent UI finish review returned `ship`;
the detector returned no findings. Its verdict covers these synthetic states, not
model quality or customer acceptance. Native backup/restore and its focused style
check passed against this schema; all three endpoint registries stay empty there.
Direct risk review/native audits used; Ponytail Audit and CE Code Review remain
unavailable. No live provider, customer data or new dependency.

GitHub CI for #160 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36803288571)).
The hosting config check parses Compose YAML, checks its exact PostgreSQL pin and
default-deny corpus registry forwarding. An immutable public OCI index fetch
matches the configured SHA-256 and includes Linux amd64/arm64 entries. Static
matcher review found that `!.keep` never restored nested runtime markers; explicit
paths now do. Bundler config, nested Rails keys and generated assets stay outside
the context. RuboCop passes; 8 focused preflight/setup tests / 38 assertions pass.
The preceding full application CI remains the broader evidence; no app code changed.

A disposable tracked checkout, empty inherited environment, production-only bundle,
dummy secret and unused database URL passed native production `assets:precompile`
and `zeitwerk:check` as UID 1000. All 30 manifest entries resolve to files, including
local fonts/CSS. The first inspection assumed an old manifest shape and failed;
the corrected check reads `digested_path`. Rails still warns about unused image
variants and non-eager-loaded test mail previews; no dependency was added to hide
them. This checks native production build/eager loading, not an image or clean host.

The initial orb had Docker 29.8.1 but no daemon socket, Compose or Buildx plugin;
its local-only probe failed before any build. A follow-up starts a private local
daemon with no bridge/iptables changes and builds the tracked #161 tree with the
existing legacy builder. The pinned Ruby image, production-only bundle and asset
build pass. A network-disabled, capability-free image executes eager loading as
UID 1000, resolves all 30 compiled assets, writes its runtime directories and has
no Git data, Rails keys or local Bundler config. This is image execution evidence,
not Compose, a clean host, TLS or production acceptance. No live runner is connected.

GitHub CI for #161 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36804432565)).

Batch discovery's focused native checks pass: 14 tests / 208 assertions. The
106-conversation fixture puts the destructive minority beyond the first batch;
all members, exact quotes and candidate definitions survive reduction. Tests
reject omitted/duplicate/foreign references and invented quotes, stop later calls
on failure/abstention/revocation, prevent claimed-work continuation, enforce SQL
receipt immutability and preserve fixed inputs after later conversation intake.
Exact Unicode/escaped JSON checks distinguish 256 KiB from two bytes over it.

Combined working-tree `bin/ci` passed in 3m17.02s: 265 Ruby files clean, native
audits clean, Brakeman zero warnings/errors, eager loading passed, 305 Rails tests /
3053 assertions and 24 browser tests / 897 assertions, no failures/errors/skips.
That run also includes the parallel failure-matching slice. The first combined
run failed a test that tried to sign out with navigation closed; it now follows
the existing navigation path. No product guard changed for that test.

The bounded UI finish review found consent before the mobile preview and misleading
queued labels on stopped calls. The preview/call ceiling now precede consent;
the full record list expands without a long forced scroll. Unsent stopped calls
say so without rewriting their ledger. Four affected browser journeys then pass
with 179 assertions, including exact-source inspection, keyboard consent, mobile
geometry and terminal labels. Desktop/390px recaptures were inspected with no
overflow/CSP failures; the scoring pass returned `ship` for those two fixes.
Selection remains unreviewed. Final-call cost is not a batch total.

`bin/prove-backup-restore` now retains batch membership, UUIDs, terminal receipts
and model results. Exact table fingerprints, 15 populated immutable tables,
no resend after restore and prior regression/calibration protections pass. It
uses synthetic approval and stubbed transport, then returns the registry to empty.
Existing lab/legacy data stays untouched. Direct risk review/native audits used;
Ponytail Audit and CE Code Review remain unavailable. No real data, live provider
or new production dependency.

GitHub CI for #162 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36808686665)).

Failure matching's final `bin/ci` passed in 3m58.90s: 265 Ruby files clean,
native audits clean, Brakeman zero warnings/errors and eager loading passed;
305 Rails tests / 3053 assertions and 24 browser tests / 903 assertions, no
failures/errors/skips. Asymmetric checks distinguish changed input from replay,
entitlement conflicts from equal facts, null/false/zero/absence, later versions
from the first hundred, current from expired/stale/merged/rejected/foreign evidence,
and page-two history from latest author decisions. Multi-trace retrieval loads the
candidate corpus once. Ruby/SQL updates and foreign relationships fail; purge
cascades decisions. GETs queue nothing and write no records. Association does not
approve, revise, compile, execute, label calibration or admit regression.

The browser appends an expert correction, retains a stale-form reason and checks
empty/viewer states. Desktop/390px captures were inspected with exact links,
conflicting facts, labelled controls, latest/earlier history and no overflow/CSP
failures. The updated `bin/prove-backup-restore` passed with exact association
history, 16 populated immutable tables and same-/foreign-workspace SQL rejection,
without changing expert approval, calibration labels or fixed-case identity.
Its focused RuboCop and `git diff --check` pass. No provider, real data or dependency
was introduced. Direct risk review/native audits used; named review tools unavailable.

GitHub CI for #163 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36809475233)).

Production-boundary `bin/ci` passed in 4m5.46s: 267 Ruby files clean, native
audits clean, Brakeman zero warnings/errors, eager loading passed; 309 Rails tests /
3083 assertions and 24 browser tests / 903 assertions, no failures/errors/skips.
Four focused configuration tests check runtime secret/role separation, equal-password
rejection without secret output and refusal to grant outside production. The deleted
web-start migration wrapper cannot race jobs. Preparation explicitly precedes both.

`bin/prove-container-runtime` passed against the built Rails image and pinned
PostgreSQL 16.15 image in three private network-disabled, capability-free containers.
Real preparation/grants cover primary/cache/queue/cable. Runtime is UID 1000 and
cannot disable audit/item triggers, create tables/roles/databases or become the
preparation role. Synthetic intake queues native work; a separate jobs process
completes the expected two-family analysis. Cache write/read, cable access and
audit rewrite rejection pass. No administrator credential reaches web/jobs.

A finite private TLS proxy validates its generated chain/hostname, production
sign-in, HSTS/CSP/secure cookies, compiled CSS (public cache max-age 31556952) and
foreign Host rejection. The proof cleans only its own containers, databases,
directory and generated test secrets; the global daemon and lab/legacy databases
stay untouched. Initial proof errors concerned service-name bounds, the pinned
initializer clearing PGHOST, asynchronous container readiness and the cache-year
expectation. No security guard was weakened. Stopped created-state test containers
are explicitly removed. Focused proof-script RuboCop and diff checks pass.
This is not Compose, an external clean host, public TLS, egress-policy, SMTP/OIDC,
production backup or upgrade acceptance. No production service or dependency was
added, and no real credential, customer data or live provider was used.

An independent partial Compose trial later ran archived #166
([`389162e`](https://github.com/glnarayanan/navishai/commit/389162e)), with
only built web/jobs image-name substitutions and no topology/security overrides.
Official Compose v2.39.4 was downloaded privately and its published checksum
verified; global plugins remain absent and no production dependency was installed.
The existing parent-owned private daemon used separate vfs data/exec/pid roots,
no bridge/iptables/masquerade/userland proxy and socket
`tmp/navishai-image-proof/docker.sock`. Four-database preparation/runtime roles,
separate web/jobs, synthetic two-family analysis, cache/cable and audit denials passed.

PostgreSQL had no published port/default route and only an internal control network.
PostgreSQL-to-web TCP passed; PostgreSQL-to-edge returned `Network unreachable`.
Web had an edge default route and container `/up` returned 200. Inspection showed
`127.0.0.1:3000:3000`, but host curl timed out after 5001 ms with HTTP 000.
The cause is unverified; daemon flags are not a proved cause. A TEST-NET probe
does not prove useful public egress or allowlist enforcement. This is partial local
evidence, not green Compose/egress/deployment acceptance, and has no tracked proof
script. It does not replace the passing private socket/TLS runtime proof.

The worker cleaned only its project/volumes/networks/secrets/private CLI/archive/new
image. Parent inspection found no containers and only host/none networks. No global
daemon, firewall or network-policy changes occurred; the private daemon stayed
running after the trial for later scoped cleanup. Clean-host, public TLS and production backup acceptance remain unverified.
See [deployment evidence](./DEPLOYMENT.md#partial-disposable-compose-trial).

GitHub CI for #164 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36811262222)).

Retained-source download is built: managing roles confirm the exact source name,
choose a fixed current/historical snapshot and receive complete normalized JSON.
Scoped reads, fresh membership/expiry, CSRF, ID-only filenames, no-store/nosniff,
2000-record/10-MiB refusal, nested masking and content-free snapshot audit are tested.
Downloads are not original/vendor files and cannot be recalled by local purge.
The actual browser download retains the historical snapshot, masked Unicode text
and one preparation audit; its private temporary file is removed. Desktop/390px
form/history/error/viewer captures were inspected without overflow/CSP failures.

Combined working-tree `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 4m44.99s:
274 Ruby files clean, native audits clean, Brakeman zero warnings/errors and eager
loading passed; 327 Rails tests / 3529 assertions and 26 browser tests / 1027
assertions, no failures/errors/skips. This also covers the saved-result calibration
slice. Three focused browser journeys pass with 165 assertions. The first download
check used a nonexistent test attribute after receiving the correct file; the
corrected check now derives expected masked text independently. Direct risk review
and native audits used; named review tools remain unavailable. No customer data,
live provider or dependency was introduced.

Saved-result calibration retains one exact result/case/output, with explicitly
chosen cohort and fixed grader check. Forged JSON, wrong/foreign cases, stale or
unapproved definitions, expiry and execution errors are refused. Manual or other
result provenance cannot be replaced by deduplication. Migration backfills existing
manual samples' cases while preserving outputs, cohorts, predictions and labels;
composite foreign keys bind optional saved results to the same case/workspace/corpus.
No provider, judge or expert label runs automatically.

The live browser selects a result and development cohort, retains a concurrent
manual-provenance error, labels a fresh blind sample, then reveals exact result/run
links and the separate prediction. Desktop/390px captures were inspected, with no
overflow/CSP failures. The combined CI evidence above includes this slice.
`bin/prove-backup-restore` passes with exact saved-result development provenance,
unchanged manual held-out label history, all table fingerprints, 16 populated
immutable tables, foreign isolation and no resend. It removes only its disposable
databases/archive. This connects results to calibration intake. The later local
development preview tests revised deterministic graders without rebinding artifacts.

GitHub CI for #165 and #166 passed
([source run](https://github.com/glnarayanan/navishai/actions/runs/36813755668),
[calibration run](https://github.com/glnarayanan/navishai/actions/runs/36813916792)).
Earlier failed #155/#158 runs remain failed; none of these PRs was merged.

Response-scoped transcript checks use fixed v2 definitions without changing old
v1 records or semantics. Each matching user turn checks only its following assistant
reply block. Earlier/user-only/unrelated later mentions cannot pass; repeated anchors,
missing/blank replies, Unicode/case and malformed definitions are tested. The
two-line form retains errors with a specific repair message and four visible rows.
These grade recorded transcripts, not meaning or incremental target execution.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 4m40.46s: 277 Ruby files clean,
native audits clean, Brakeman zero warnings/errors, eager loading passed;
333 Rails tests / 3660 assertions and 27 browser tests / 1096 assertions,
no failures/errors/skips. Focused native checks pass with 11 tests / 198 assertions;
the browser journey passes with 69 assertions. An exact source-backed fixture
requirement fails a misleading earlier mention, receives human regression admission
and a separate blind development label, then passes on the same fixed case after
target correction. Duplicate delivery calls the scripted target once per run;
hidden facts stay absent and grader revision cannot rewrite prior results.

Desktop/390px form/error/failure/pass captures were inspected. The first inspection
found generic error text and a clipped malformed value; the final error names the
two-line rule and displays the full retained value. A fixture approval lacked a
required outcome; corrected that fixture without weakening the approval gate.
No overflow/CSP failures, dependency, live provider or customer data. Backup/restore
and diff checks pass too. Direct risk review/native audits used; named reviews
remain unavailable. Interactive turn execution and grader-revision development
comparison remained engineering work after that slice, not pilot-data approval gates.

Revised-grader previews reuse fixed development outputs and the latest labels on
original requirements. They accept only a newer deterministic version of the same
scoped grader; held-out data, judges, foreign definitions and stale cases are refused.
Candidate matrices stay separate from saved predictions and the original review
queue. No label, prediction, approval, audit or job is written. Meaning changes
need new labels; fresh held-out calibration remains necessary. Candidate sample
links also respect the reviewing expert's first-label hiding.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 4m35.03s: 281 Ruby files clean,
native audits clean, Brakeman zero warnings/errors and eager loading passed;
340 Rails tests / 3722 assertions and 28 browser tests / 1158 assertions,
no failures/errors/skips. Asymmetric evidence distinguishes the original two true
positives from the candidate's one missed failure. Disputes stay excluded, appended
corrections affect counts without rewriting history, and fixed predictions remain
unchanged. The live browser retains the preview on refresh, follows an already
labelled disagreement, refuses held-out tuning and renders an empty revised set.
Desktop/390px preview, refusal and empty captures were inspected without
overflow/CSP failures. Direct risk review/native audits used; named reviews remain
unavailable. No provider, customer data, dependency or training was used.

GitHub inspection on 1 October found #167 and #168 open and unmerged.
#167 CI passed ([run](https://github.com/glnarayanan/navishai/actions/runs/36815505174));
#168 CI passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36817164500), completed
04:56:32 UTC). The local full CI counts above remain separate evidence.
The actual failed #155/#158 runs remain failed. No PR was merged, released or deployed.

Bounded conversations now use immutable expert-authored follow-up plans and the
generic `support-conversation-v1` target protocol. The first call excludes future
messages; only the latest assistant reply can release the next one. An unmet
literal stops later disclosure. All calls recheck access, source/approval lifetime
and exact endpoint authority. Single-shot adapters refuse plans. The maximum is
eleven calls per case; consent names each fixed plan and transcript forwarding.
Assistant-only outputs form the actual transcript with ordered tool/citation
reports, latest field values and terminal escalation/policy. Aggregate bounds stop
further disclosure immediately, without truncation. Content-free receipts retain
turn keys/digests/timing and unknown/error outcomes where authority permits;
crashes before retention cannot preserve them. Neither receipts nor reported tools
prove remote execution. Hidden facts/expectations/labels stay outside target fields.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 4m52.14s: 285 Ruby files clean,
native audits clean, Brakeman zero warnings/errors and eager loading passed;
349 Rails tests / 3825 assertions and 29 browser tests / 1216 assertions,
no failures/errors/skips. Tests distinguish later release from sending the full
plan, latest from earlier/user-only conditions, ten/eleven and byte boundaries,
invalid user injection, revoked access/expiry/approval/endpoint and interruption,
unknown outcomes/no resend, and fixed failure → reviewed regression → corrected pass.
Omitting a plan preserves it; explicit [] removes it only in a new version.

Direct review found two bugs and proved each with a failing test: overflow allowed
later calls, and an omitted edit field erased the plan. Both fixes pass the full
suite. The worker's initial browser command ran all journeys and exposed a frozen
proposal-schema coupling and a new-test selector error; focused affected journeys
and the final full suite pass after fixes. Old model proposal schemas stay fixed.
Desktop/390px error, case, disclosure and result captures were inspected without
overflow/CSP failures. Backup/restore of the changed schema passes with PASS/CLEAN;
the private Docker proof daemon and only its own directory are now removed.
Direct risk review/native audits used; named reviewers remain unavailable.
No provider, customer data, dependency, training, merge, release or deployment.

GitHub CI for #169 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36818942440)).
GitHub CI for #170 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36820161725), completed
05:34:58 UTC on 1 October). Both PRs remain open and unmerged.

The revised-judge browser journey saves a new rubric version, compiles a new fixed
case and creates separate calibration evidence. Its fresh held-out sample inherits
neither labels nor predictions. Missing disclosure refuses a request; duplicate
delivery sends one fixture judge call. Prediction stays hidden until a fresh expert
label. A deliberately wrong high-confidence judgment yields one false positive,
not the original development sample's true positive. Database reloads confirm the
original label history, prediction and development report remain unchanged.

Combined `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m19.37s: 285 Ruby files
clean, native audits clean, Brakeman zero warnings/errors and eager loading passed;
349 Rails tests / 3825 assertions and 30 browser tests / 1281 assertions,
no failures/errors/skips. After strengthening the history check to reload the
database, the focused revised-judge journey passed with 65 assertions; focused
RuboCop and diff checks pass. Inspected 2x desktop/390px empty, blind and held-out
captures show unknown rates, first-label hiding and the false-positive report,
without page overflow or CSP violations. This proves versioned review and separate
measurement, not live judge quality or customer labels.

`bin/prove-backup-restore` also passed with PASS/CLEAN. It now retains a fixed
expert-approved conversation plan, actual four-turn transcript, passing result
and exact terminal turn keys/receipts. The first fixture request omits the future
message and hidden facts. Duplicate delivery before and after restore makes no
extra target call. All complete-table fingerprints, 16 populated immutable tables,
calibration/association history, batch receipts, isolation and audit protections
still pass. Both fixture approvals return to empty before backup; no live endpoint
is called. Only disposable databases/archive are removed. Direct risk review and
native audits used; named reviews remain unavailable. No new production dependency.

GitHub CI for #171 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36822648561), completed
06:05:20 UTC on 1 October). The PR remains open and unmerged; earlier failed
#155/#158 runs remain failed.

A controlled private-namespace ingress comparison held the pinned Ruby helper and
Docker flags constant except userland proxy. Disabled: HTTP 000, curl exit 28,
5001-ms timeout. Enabled: HTTP 200 in 0.001339s. Direct-container HTTP 200 passed
in both. This establishes that flag's effect in the reproduction, not the removed
daemon's exact failure cause. Namespace-local synthetic TLS also distinguished
edge reachability from internal-control ENETUNREACH. No shared policy changed.

`bin/prove-compose-runtime` then passed against a tracked
[`f11ae5d`](https://github.com/glnarayanan/navishai/commit/f11ae5d) archive in 355.67s before cleanup.
The private official Compose checksum, pinned PostgreSQL image identity after
save/load, separate four-database preparation/runtime roles, web/jobs, loopback
production health, actual UID/capability/privilege denials, cache/cable/audit and
completed synthetic two-family analysis pass. PostgreSQL has no publication/default
route and reaches web over control; web reaches an edge-only trusted local TLS peer
while PostgreSQL gets ENETUNREACH. Only disposable image/project names differ from
the composition. Daemons, mounts, images, volumes, secrets and archives were cleaned;
only existing web/portal services remain. This is local Compose evidence, not public
egress, endpoint policy, clean-host, public TLS or deployment acceptance.

The shared test-only runtime payload removes duplication from the socket proof and
adds actual capability/no-new-privileges checks. Combined native CI passed in
4m32.04s: 286 Ruby files clean, native audits clean, Brakeman zero warnings/errors
and eager loading passed; 349 Rails tests / 3825 assertions and 30 browser tests /
1281 assertions, no failures/errors/skips. Three focused proof files pass RuboCop
and syntax checks. A supplied global-daemon argument is refused before resources
are created. Direct code/risk review used; named reviews remain unavailable.

The independent rerun first failed PostgreSQL startup under caller `umask 077`.
A minimal extraction check proved that mask produced initializer mode 600,
unreadable by PostgreSQL UID 999, and Rails entrypoint mode 700. The proof now sets
its own file mask while keeping its private directory/secrets explicitly 0700/0600;
failure diagnostics are bounded and redact generated secrets before cleanup.
`umask 077; bin/prove-compose-runtime` then passed every check in 371.22s before
cleanup, including exact HTTP 200, and printed CLEAN. All private daemons/mounts
were removed; existing web/portal services remain. No app control was weakened.

GitHub CI for #172 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36829152089), completed
07:17:46 UTC on 1 October). The PR remains open and unmerged; earlier failed
#155/#158 runs remain failed.

The matched-trace journey now opens the exact existing version with the retained
trace selected, but no copied facts, correction, requirements, quote or approval.
Experts explicitly edit, attach an exact excerpt, save, review and compile. Old
versions/cases/associations stay fixed; distinct same-source trace records retain
their evidence. Historical trace snapshots remain eligible until expiry, while
outdated document attachments are refused. Invalid quotes roll back, retain input
and expose an adjacent repair alert with aria-invalid/describedby.

Focused checks pass: 13 model/access tests / 157 assertions and three affected
browser journeys / 139 assertions. The connected journey grades the exact recorded
failure, records expert regression admission, then passes a corrected scripted
target on the same new fixed case. No new root scenario or human label is fabricated.
Desktop/390px selected/error/regression captures were inspected. Initial targeted
crops clipped intact controls; viewport captures avoid that capture error. Full
trace titles remain readable outside native single-line pickers. Direct risk review
covers lifetime/scope, rollback, unchanged history and target-hidden facts. Named
review tools remain unavailable; native audits provide the executable checks.

Final `bin/ci` passed in 3m56.73s: 286 Ruby files clean, gem/importmap audits
clean, Brakeman zero warnings/errors and eager loading passed; 352 Rails tests /
3878 assertions and 31 browser tests / 1351 assertions, no failures/errors/skips.
`bin/prove-backup-restore` passed with PASS/CLEAN: exact table fingerprints,
16 immutable tables, calibration/association history, fixed conversation/batch
receipts and no resend survived restore. Only its disposable databases/archive
were removed. No customer data, provider, dependency, merge, release or deployment.

GitHub CI for #173 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36832587143), completed
07:52:44 UTC on 1 October). The PR remains open and unmerged; failed #155/#158
runs remain failed.

Family evidence now explores every fixed member with full-family denominators,
exact true/false/missing-nonboolean reports, reported critical impact and separate
literal mentions on complete retained text. Local/model families use the same
rules; proposed importance cannot supply source counts. Filters paginate 50 records
and preserve historical source links after a new export. Foreign/expired inputs
and oversized text/context are refused. Inspection writes no records, audits or jobs.

The browser follows record 51 from a refreshed filtered page to snapshot 1, then
repairs empty and invalid filters. Desktop/390px captures were inspected, with
intact controls, complete escaped text/context, no overflow and no CSP failures.
The desktop uses the existing compact field grid; mobile keeps source order.
Two first-run failures concerned a missing job-test helper and an immediate URL
assertion racing Turbo; the corrected journey passes with 66 assertions.

Full CI first failed Brakeman's refresh-link check. A crafted query reproduced an
actual javascript-scheme link; the same routing pattern affected shared pagination.
Refresh now uses the fixed family route, and pagination passes filters only as
query data with a local path. The regression checks both links. The final combined
working-tree `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m24.88s: 295 Ruby files
clean, native audits clean, Brakeman zero warnings/errors, eager loading passed;
370 Rails tests / 4104 assertions and 33 browser tests / 1481 assertions, no failures,
errors or skips. These totals also include the separate pending calibration-cost
slice; they are not a remote-CI claim. Direct risk review used; named review tools
remain unavailable. No provider, customer data or dependency was introduced.

Calibration sets now retain optional human-supplied false-positive/false-negative
costs, common units, rationale and creator/version. All fields or none; existing
sets stay unknown and no values carry over. Raw validation and database checks
reject excess precision instead of rounding. Untyped numeric plus a scale check
avoids PostgreSQL's typmod rounding before CHECK. Exact asymmetric tests distinguish
25 from 23.75 after an appended correction, separate candidate/cohort counts and
unknown evidence from observed zero. Disputes, uncertainty and unusable predictions
cannot supply a cost. Immutable triggers and scoped access remain intact.

The browser repairs retained raw inputs, sees unknown empty costs, labels blindly
and then sees one false positive costing 1.25 fixture units. Desktop/390px captures
were inspected with readable assumptions, full repair controls and no overflow/CSP
failures. The combined CI above covers this slice. `bin/prove-backup-restore` passed
with PASS/CLEAN, exact six-place cost assumptions and author/version, unknowns,
unchanged labels/associations/conversation/batch receipts, 16 immutable tables and
no resend. Only its disposable databases/archive were removed. Direct risk review
and native audits used; named review tools unavailable. No customer cost policy,
spend, provider, data, dependency, training, merge, release or deployment was chosen.

GitHub CI for #174 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36837357438), completed
08:39:53 UTC on 1 October); #175 passed
([run](https://github.com/glnarayanan/navishai/actions/runs/36837670586), completed
08:43:19 UTC). Both exact branch heads remain open and unmerged. The earlier
failed #155/#158 runs remain failed.

Calibration reports now display their exact fixed judge abstention threshold beside
counts, explain strict-below/equality and distinguish confidence from calibrated
probability. Deterministic reports/previews show not applicable. A new access test
failed before implementation, then proved that a later 0.95/current-kind edit cannot
replace the original 0.8 rule or change labels/predictions/jobs. The browser retains
0.8 on the old set, shows 0.95 on a fresh set and obtains separate held-out labels.
The first browser attempt used the wrong existing field label; the corrected four
affected journeys pass with 275 assertions. Inspected 2x desktop/390px captures show
fixed/new/empty rules and deterministic costs without clipping, overflow or CSP
failures. The boundary execution tests still distinguish below from equality.

Final `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m28.73s: 295 Ruby files clean,
native audits clean, Brakeman zero warnings/errors and eager loading passed;
371 Rails tests / 4129 assertions and 33 browser tests / 1494 assertions, no failures,
errors or skips. Eleven focused access/grader tests pass with 174 assertions.
No backend semantics, schema, provider call, labels or thresholds were changed by
the feature. Direct risk review/native audits used; named reviews remain unavailable.

GitHub CI for #176 passed at its exact head
[`913502b`](https://github.com/glnarayanan/navishai/commit/913502bf653cbacb7596db8b9218e371157f31a4)
([run](https://github.com/glnarayanan/navishai/actions/runs/36839499430), completed
09:00:23 UTC on 1 October). It remains open and unmerged; failed #155/#158 runs
remain failed.

Complete-record guards now count rows and sum retained IDs, titles, text and context
JSON bytes before loading current or historical analysis inputs. Two individually
valid 6-MiB contexts reproduced the old aggregate bypass; a 101-record preview
also loaded all complete rows before refusing them. Both regressions now fail
before materialisation. Jobs, mining and overview use the same guard. Fixed order,
digests, membership and batch allocations stay unchanged. Two real PostgreSQL
connections prove that the corpus lock spans checks and loading, then releases.
Exact UTF-8 byte-boundary tests distinguish 10 MiB from one byte over it.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m34.39s: style, native security
audits, eager loading and Rails tests passed; 34 browser tests / 1526 assertions,
no failures, errors or skips. Focused checks covered current/fixed bounds, old
queued refusal, no proposals/retry, history, mining and concurrency. Desktop/390px
blocked-preview/history captures were inspected with readable recovery links,
no partial controls and no overflow. Browser checks reproduced Turbo's GET-422
error renderer activating inline scripts under the prior CSP. Accessible blocked
history now returns a normal page; POST validation remains 422. Final browser
checks show no CSP violations, without changing nonces or security policy.
Direct risk review/native audits used; named review tools remain unavailable.
No schema, dependency, provider, customer data or existing database changed.

GitHub CI for #177 passed at exact head
[`e70b62d`](https://github.com/glnarayanan/navishai/commit/e70b62de118c9bf9b31521f710634577d62a750b)
([run](https://github.com/glnarayanan/navishai/actions/runs/36843580014), completed
09:38:31 UTC on 1 October). It remains open and unmerged; failed #155/#158 runs
remain failed.

Family selection review now shows all fixed families, those with selected
candidates or those with none, from actual member selection. Counts remain
whole-analysis counts; ten-family pages retain focus on refresh and link exact
historical evidence after a newer export. Invalid/empty/out-of-range views offer
recovery. Viewers can filter, not mine or revise. GETs write/queue nothing and never
bypass complete-record bounds. Neither source importance nor existing scenarios
can turn these counts into verified test coverage.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m13.34s: 295 Ruby files clean,
native audits clean, Brakeman zero warnings/errors, eager loading passed;
381 Rails tests / 4407 assertions and 36 browser tests / 1580 assertions, no failures,
errors or skips. Focused checks pass with 14 model/access tests / 317 assertions
and eight browser journeys / 283 assertions. The asymmetric fixture has twelve
distinct families, one selected critical record and eleven unselected families;
later intake cannot change that partition or full-analysis totals. Native tests
also reject route-option injection and cross-workspace access.

Desktop/390px focused, invalid and empty captures were inspected. The first
viewport captures cut off intact lower controls; full-height recaptures now show
complete alerts, links and controls. Those two focused journeys pass again with
54 assertions and no overflow/CSP failures. Earlier permission assertions counted
the layout's legitimate sign-out form; they now check analysis controls separately.
Direct risk review/native audits used; named reviews remain unavailable. No schema,
provider, customer data, dependency, label, merge, release or deployment changed.

GitHub CI for #178 passed at exact head
[`199059f`](https://github.com/glnarayanan/navishai/commit/199059f4809bb76209b14a4da9fe98d9a0bfe00e)
([run](https://github.com/glnarayanan/navishai/actions/runs/36845529840), completed
09:56:27 UTC on 1 October). It remains open and unmerged; failed #155/#158 runs
remain failed.

Two failing native tests reproduced javascript-scheme pagination links on corpus
and source-impact pages when a query supplied host/protocol. Those pages now keep
query values under params and force local paths, with fixed fragments. No wrapper,
security-policy relaxation or unrelated route change. Tests follow next/previous
links and preserve phrase/source filters, snapshot/record position and independent
dependency/case pages. The shared record helper's return navigation also passes;
it needed no change. All remaining query merges in views use the safe pattern.

`bin/ci` passed in 4m17.70s: 295 Ruby files clean, native audits clean, Brakeman
zero warnings/errors and eager loading passed; 381 Rails tests / 4443 assertions
and 37 browser tests / 1601 assertions, no failures, errors or skips. Focused checks
pass with eleven access tests / 223 assertions and four browser journeys / 127
assertions. The crafted-query browser journey uses Enter for next and returns to
page one at the same origin with retained filters, no writes and no overflow/CSP
violations. Appearance is unchanged. Direct risk review/native audits used; named
reviews remain unavailable. No schema, provider, customer data or dependency changed.

GitHub CI for #179 passed at exact head
[`abfe8eb`](https://github.com/glnarayanan/navishai/commit/abfe8eb8806d720ff3e9c4fe75c37c28b70fbce6)
([run](https://github.com/glnarayanan/navishai/actions/runs/36847213277), completed
10:12:27 UTC on 1 October). It remains open and unmerged; failed #155/#158 runs
remain failed.

Expert nomination now turns one fixed record into a local unapproved draft with
source evidence, author and reason. The method's selection/totals, model result,
prior versions and labels stay unchanged. Repeats open the existing scenario,
including an approved one. Foreign, viewer, expired and malformed requests fail
without partial writes or jobs. Maximum-length Unicode reasons remain valid.
POST repairs retain the record/reason/filter/page; GET recovery uses fixed local
routes. Six desktop/390px form, repair and existing-scenario crops were inspected;
the browser checks keyboard submission, retained spaces, ARIA, no overflow/CSP,
historical record 51 and unchanged selection after a newer export.

Final `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m16.24s: 295 Ruby files clean,
native audits clean, Brakeman zero warnings/errors and eager loading passed;
387 Rails tests / 4553 assertions and 38 browser tests / 1673 assertions,
no failures/errors/skips. Focused checks passed with 27 native tests / 396 assertions
and seven affected browser journeys / 305 assertions. The first full run hit an
existing same-page refresh stale element. A held response proves the old counts
satisfy the prior assertions while refresh remains busy; the journey now waits for
settled navigation. The second run found a hidden nomination field during return
navigation; explicit page/disclosure waits now pass without changing product code.
Direct risk review/native audits used; named review tools remain unavailable.
No schema, dependency, provider, customer data, training, merge, release or deployment.

GitHub CI for #180 passed at exact head
[`bbea1e2`](https://github.com/glnarayanan/navishai/commit/bbea1e23d05e3f688a96808e0e71ad88fb5533cb)
([run](https://github.com/glnarayanan/navishai/actions/runs/36851369957), completed
10:50:58 UTC on 1 October). It remains open and unmerged; failed #155/#158 runs
remain failed.

Exact replay discovery now searches all fixed corpus cases and loads only paged
IDs/titles. A 102-case regression found one match instead of two before the fix;
the late match now appears. Database comparison uses retained trace IDs, never
input text in SQL. Asymmetric tests cover Unicode, typed/missing facts, ordered
arrays and knowledge, foreign/wrong-kind traces and expiry. Page counts and links
remain separate from expert association, current approval and execution eligibility.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m37.57s: 295 Ruby files clean,
native audits clean, Brakeman zero warnings/errors and eager loading passed;
390 Rails tests / 4655 assertions and 39 browser tests / 1734 assertions,
no failures/errors/skips. Five affected browser journeys passed with 259 assertions.
The new journey follows match 51 on a retained historical trace, uses Enter for
next, refreshes, recovers from an empty page and repeats as a viewer without writes
or jobs. An initial test forgot to open the existing sign-out menu; corrected it.
The first narrow element crops clipped intact text. A full-width capture repair
passed the two focused journeys again with 112 assertions; desktop/390px matching
and empty-page controls were inspected. No overflow or CSP violations. Direct risk
review/native audits used; named reviews remain unavailable. No schema, provider,
customer data, dependency, label, merge, release or deployment changed.

GitHub CI for #181 passed at its exact head
([run](https://github.com/glnarayanan/navishai/actions/runs/36854187687), completed
11:19:33 UTC on 1 October). It remains open and unmerged; failed #155/#158 runs
remain failed.

## Intake integrity (slice 42)

Red tests reproduced recursive email-key value loss and reuse of an older
processor's snapshot. Intake now validates normalized masking before any lookup
or source/retention mutation, including repeated uploads. Distinct masked keys
(including false/nil and nested arrays) or IDs refuse the whole batch with a
content-free rename/retry error. Original-text mode stays an explicit choice.
Historical output stays fixed, not repaired. Lookup and SQL uniqueness include
processing version; identical bytes under changed processing create a new snapshot.
Only configured lab databases received the index migration; old databases remain
untouched.

`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m13.89s: 296 Ruby files clean,
audits/eager loading passed, 397 Rails tests / 4765 assertions and 40 browser
tests / 1767 assertions, no failures/errors/skips. These combined working-tree
checks also include the next SQL-debug-log privacy slice; they are not remote CI
evidence for either new branch. A separate full browser run passed with the same
40 tests / 1767 assertions. Earlier full runs exposed two existing browser races:
opening a disclosure before refresh replaced it, and visiting home before sign-out
finished. Controlled refresh replacement and awaiting the sign-in redirect fix
the tests without changing authentication or weakening assertions. Those test
fixes have separate commits.

The collision journey uses Enter, confirms no records/jobs or source/retention
changes, and inspects the retained original snapshot. Fresh desktop/390px form
and alert captures remain readable without overflow or CSP violations.
`bin/prove-backup-restore` passed with exact fingerprints and sixteen immutable
tables; only disposable proof databases/archive were removed. Direct risk review
and native audits used; named reviews remain unavailable. No dependency, provider,
customer data, authoritative label, merge, release or deployment changed.

## Rails SQL-log privacy (slice 43)

An actual DEBUG logger probe disproved SQL interpolation: Rails already kept
the phrase out of SQL statements. It did expose the anonymous bind value in logs.
The search now uses a typed `corpus_query` bind, and Active Record shares the
existing configured request filters. Actual search and insert logs hide the
phrase and configured content/context values while results and stored text stay
unchanged. Existing literal wildcard, Unicode, tenant/source, bounds and paging
tests pass. This is Rails filtering, not a database/proxy/operator-log guarantee.

Eight exploration tests include two logging regressions. The combined intake,
trace and exploration check passed 25 tests / 463 assertions. The full native CI
and rendered journey evidence recorded for slice 42 includes these changes.
Ruby style/eager loading also passed immediately before commit; no app code changed
after the full run. #182 has been pushed with an open stacked PR; its remote CI
is separate and was still pending when this slice was prepared. No merge,
release, deployment, live disclosure/spend, dependency or authoritative label.

Later exact-head remote evidence: #182 passed run
[36859087652](https://github.com/glnarayanan/navishai/actions/runs/36859087652)
at 12:05:12 UTC; #183 passed run
[36859246828](https://github.com/glnarayanan/navishai/actions/runs/36859246828)
at 12:07:57 UTC on 1 October. Failed ancestor #155/#158 runs remain failed.

## Explicit exact-text masking (slice 44)

Authors may choose a separate literal, case-sensitive mode with 1–50 unique
values, 3–200 characters each, at most 8 KiB total. Longer matches win at the
same position; strings and JSON keys are masked, other scalar types stay fixed.
Snapshots retain the sorted unique list's fingerprint/count, not its raw values.
Changed rules create new versions. Errors clear private values but keep the mode;
entered rules in other modes refuse rather than silently doing nothing. Structural
trace/key/identity collisions refuse atomically. Source names and older history
stay unchanged. Masking never proves PII removal or approves disclosure.

Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m4.54s: 404 Rails tests /
4992 assertions, 41 browser tests / 1825 assertions, no failures/errors/skips;
297 Ruby files clean, audits and eager loading passed. Focused checks passed
37 tests / 939 assertions and four browser tests / 159 assertions. Desktop,
390px and 320px form/repair/source captures were inspected for clear privacy
limits, private errors and readable wrapped digests; no overflow/CSP violations.
`bin/prove-backup-restore` passed with exact masking-history/fingerprint/content
and rule-aware reuse checks across sixteen immutable tables; only disposable
proof databases/archive were removed. Direct risk review and native audits used;
named reviews remain unavailable. Remote CI for this branch has not run yet.
The owner-owned lockfile remains untouched and unstaged. No live customer data,
provider, dependency, expert label, merge, release or deployment changed.

Later exact-head remote evidence: #184 passed run
[36863533615](https://github.com/glnarayanan/navishai/actions/runs/36863533615)
at 12:46:52 UTC on 1 October. No ancestor failure changed.

## Bounded analysis review (slice 45)

Local overview loads only ten examples per displayed family, selected first with
stable ties. Family pages load only their fifty complete records; typed SQL counts
keep true/false/missing separate, and 100-record scalar scans keep the original
Ruby mention rules over complete text. Counts retain the whole fixed denominator,
including late/beyond-window mentions. Mining loads chosen records plus linked
expectation evidence, not every fixed row. Full-input bounds/lifetime still run
before partial reads; later or foreign snapshots cannot enter them. Corpus locks
cover checks, counts and page loading. Model disclosure inputs stay complete and
unchanged. Family byte guards now include IDs/titles as well as text/context.

Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m16.77s: 409 Rails tests /
5044 assertions, 41 browser tests / 1825 assertions, no failures/errors/skips;
style, audits and eager loading passed. Focused checks passed 64 tests /
948 assertions, including concurrency, batch/model evidence and mining. Actual
query/instantiation evidence shows text scans of 100 + 65 rows with no complete
source objects, ten overview rows, five second-page rows, zero invalid/empty rows,
and one nomination row. A new test initially inspected the first family globally;
scoping its DOM lookup to the intended family fixed the test, not the selection.
Desktop/mobile filtered, empty, invalid and nomination journeys passed; final
captures were inspected for full counts, escaped source text, readable context
and recovery. DOM checks cover alert semantics, keyboard actions and viewer gates.
Direct risk review/native audits used; named reviews remain unavailable. These
are local checks; this branch has no remote CI yet. No limits, discovery method,
dependency, provider approval, expert label, merge, release or deployment changed.

Later exact-head remote evidence: #185 passed run
[36866373549](https://github.com/glnarayanan/navishai/actions/runs/36866373549)
at 13:11:36 UTC on 1 October. Failed ancestor runs remain failed.

## Streaming local processing (slice 46)

The same local method now reads scalar batches in fixed external-ID/ID order,
keeps sparse term counts/global frequencies and skips zero-overlap seed comparisons.
It does not independently cluster batches or load complete source objects/context.
Full-text signals, exact JSON critical/reopen flags, centroid ties, labels,
selection reasons, document gaps and fixed membership retain their semantics.
Bulk member inserts stay inside the checked job transaction and database guards.
No analysis, disclosure, candidate or input limit increased in this refactor.

Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 5m24.32s: 410 Rails tests /
5059 assertions, 41 browser tests / 1825 assertions, no failures/errors/skips;
style, audits and eager loading passed. Focused checks passed 48 tests /
751 assertions. A temporary comparison with the exact pre-refactor implementation
passed 24 asymmetric datasets / 48 assertions, including reversed insertion order,
duplicate external IDs across sources, empty vectors, Unicode, strict report types
and beyond-window signals. It compared full summaries, ordered family membership,
signals, labels, selection reasons and document-gap flags; temporary files were
removed. The permanent regression proves 100 + 12 scalar rows, no source-object
loads, complete membership, a late rare risk case and stable centroid ties.
Existing desktop/mobile review journeys remain green. Native audits/direct risk
review used; named reviews remain unavailable. No remote CI yet for this branch.
Larger-local bounds and their operational proof are the next behaviour change,
not a customer-data or expert-label gate. No customer/provider data, live spend,
dependency, expert label, merge, release or deployment changed.

Later exact-head remote evidence: #186 passed run
[36869276174](https://github.com/glnarayanan/navishai/actions/runs/36869276174)
at 13:35:40 UTC on 1 October. Failed ancestor #155/#158 runs remain failed.

## Larger local analysis (slice 47)

An explicit v2 local method freezes up to 100,000 complete conversation/document
records within 1 GiB, without raising original local, model or upload limits.
It keeps global frequencies, fixed ordering and provenance. Term-entry, vocabulary
and seed-comparison caps fail atomically without sampling or retry. Vector and
centroid lengths are computed once. Post-computation access/lifetime checks prevent
expired work from committing proposals. No provider approval or expert label follows.

Complete evidence reads stay at most 10 MiB. Corpus/source/family pages preflight
their fifty rows, retain full counts and navigation on refusal, and never load a
fifty-first full record. Corpus locks cover checks/loading. Blocked streaming
overviews keep read-only family links for smaller filtered inspection; no partial
evidence or write controls appear. Source recovery warns that current search omits
historical snapshots.

Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 9m2.11s: 299 Ruby files clean,
native audits clean, Brakeman zero warnings/errors, eager loading passed; 419 Rails
tests / 5254 assertions and 43 browser tests / 1951 assertions, no failures/errors/skips.
The 12-test scale/discovery check passed with 163 assertions in 204.91s and peaked
at 517404 KiB. It processed exactly 1000 scalar batches of 100 without complete
source objects, kept every member, selected a late risk case and mined from the
fixed historical snapshot after a newer export. It refuses record 100001 and
checks exact budget edges, complete UTF-8 bytes, partial reads and expiry rollback.
The byte-cap edge uses a smaller injected bound, not a 1-GiB allocation.
This repetitive synthetic workload does not establish semantic quality or throughput
for arbitrary corpora. No customer data, provider, dependency or authoritative label.

Desktop/mobile picker, completion, failure and blocked/recovered evidence states
were rendered. Inspection caught stale viewport dimensions in screenshot capture;
the journey now waits for actual width and sets/clears 2x emulation explicitly.
The retained refusal now names the previous request rather than the newly selected
method. Final focused checks pass with 34 access tests / 705 assertions and two
browser journeys / 126 assertions; style and eager loading pass. Final 2x desktop
and mobile captures were inspected with readable controls/alerts and no overflow
or CSP violations. No application guard, style or CSP was weakened. Direct risk review/native audits
used; named review tools remain unavailable. This branch has no remote CI yet.

## Bounded source storage (slice 48)

Intake validates every item before bounded 1000-row PostgreSQL writes. Source,
snapshot, retention and audit roll back with a late invalid item, including after
an earlier batch. Returned associations contain persisted immutable records.
Unicode, nested scalar types, source identity and six-place timestamps stay intact.
The proposed `insert_all!` path failed the actual DEBUG-log privacy regression;
the final path keeps the whole batch in one filtered bind, outside SQL literals.
A separate failing test proved plain JSON encoding lost fractional seconds;
explicit six-place timestamps fix it. No intake limits or processing identity changed.

The initial combined `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 7m9.59s:
423 Rails tests / 5494 assertions and 43 browser tests / 1951 assertions,
no failures/errors/skips, with native style, security audits and eager loading.
The fractional-second correction followed that full run and passed the focused
intake/exploration tests; later combined evidence must cover its final state.
Named reviews remain unavailable; direct risk review and native audits used.
No new dependency, customer data, provider, expert label, merge or deployment.

## Retained download preflight (slice 49)

A red test reproduced one source object loading roughly 15 MiB of masked context
before export refusal. SQL now counts encoded record strings and quoted context
fragments first, under the existing corpus lock. The regression loads zero source
objects and writes no audit. This is a lower bound, not an exact encoded-size
calculation; the complete JSON limit still runs. Scientific-number expansion,
JSON spacing, escaped quotes/backslashes, Unicode and exact byte edges prove
valid exports remain valid. No download limit or permission changed.

Thirteen focused export tests pass with 408 assertions. The combined CI above
includes the guard and the real browser historical download: fixed snapshot,
masked Unicode output and one content-free preparation audit. Its temporary file
is removed. Fresh historical desktop/mobile captures were inspected for complete
warnings, confirmation and action. Native style/eager loading and direct risk
review pass; named reviews remain unavailable. No remote CI yet for this branch.

## Varied local proof (slice 50)

One heterogeneous synthetic workload freezes 2204 inputs: four technical term
families, two zero-term conversations and two documents. The native request/job
retains all six exact membership partitions after newer intake. Independent
expectations check overlapping vocabulary, Unicode/HTML, document presence/gaps,
true/false/nonboolean reports, late full-text risks, centroid and risk-cutoff ties,
fixed source identities and unapproved idempotent mining. This complements the
100,000-row ceiling proof; it does not prove customer taxonomy or retrieval quality.

The focused native test passes with 140 assertions in 5.23s. The first run exposed
a test query treating an empty JSON array as an SQL value-list; explicit JSONB
comparison fixes that query without changing discovery or its expectations.
Style, syntax and eager loading pass. Named reviews remain unavailable; direct
review used. Full combined checks and remote CI remain separate evidence.

## Streamed conversation intake (slice 51)

Explicit normalized conversation JSONL now accepts 60 MiB / 100,000 records,
with 1-MiB lines and 256 MiB of encoded normalized fields after masking. Other
formats, model limits and disclosure stay unchanged. Bounded tempfile reads make
two passes without a whole-file string. First-pass format/masking/identity checks
precede source mutation; second-pass validated 1000-row writes stay atomic.
Changed count/digest or a late invalid record rolls back every batch, snapshot,
source retention and audit. Retained source kind stays conversations with a fixed
new processor; historical snapshots remain unchanged. No job, approval, label or
provider starts automatically.

The initial real 100,000-record file check passed with 136 assertions in 36.37s,
peaking at 180608 KiB. It retained complete first/last Unicode and typed evidence,
used 100 bounded inserts, reused the repeat and refused actual record 100001.
Its final revision also observes every bounded line-read argument; the combined
green run covers that revision. Smaller focused checks cover exact wire/line/masked
byte edges, malformed input, duplicate/colliding IDs, roles, changed second pass,
late rollback and processor history. A multipart request above 10 MiB also passes.
Byte edges use smaller injected caps, not a 256-MiB allocation.

The live browser imports 3001 records by Enter, repairs format errors privately,
explicitly requests streaming analysis and creates two source-backed unapproved
scenarios. The focused journey passes with 72 assertions, including no automatic
jobs/writes on refusal, labelled format help and no overflow/CSP violations.
Desktop/390px form, fixed source metadata and complete masked-record captures
were inspected. A repair crop omitted the page-level alert; the capture target
now includes the whole body. Final desktop/mobile repair captures were inspected
with the alert, retained choices and intact controls. `CAPTURE_LAB_SCREENSHOTS=1
bin/ci` passed in 7m55.88s: 301 Ruby files clean, native security audits/eager
loading passed; 430 Rails tests / 5966 assertions and 44 browser tests / 2023
assertions, no failures/errors/skips. This covers final slices 48–51, including
the timestamp correction and varied proof. No remote CI for these branches yet.
Direct risk review/native audits used; named review tools remain unavailable.

GitHub #187 remains open with run
[36875739393](https://github.com/glnarayanan/navishai/actions/runs/36875739393)
in progress at the 15:11 UTC inspection on 1 October. Its `bin/ci` step began
14:22:55 UTC. The reason for that duration is unverified; no rerun/cancellation
occurred. Earlier #155/#158 failures remain failed. Local green checks cannot
replace exact-head remote evidence. No merge, release, deployment, customer data,
live provider, dependency, spend or authoritative expert label was introduced.

## Trace-match count preflight (slice 52)

A real 2000/2001-version test reproduced candidate definitions and source
associations loading before refusal: 2001 versions, scenarios and evidence entries,
then source objects. The matcher now counts bounded IDs first and holds the corpus
lock through checks/loading. At 2000 it searches the whole collection with stable
top-five rank; at 2001 it loads no candidate definitions/associations and writes
no decisions, reviews or audits. The requested trace still refreshes its own
source metadata for lifetime validation. Multi-trace pages do one scalar count
and one candidate collection load, not one search per trace.

Focused native checks pass: 14 matching/decision/access tests / 132 assertions,
with native style clean. Eligibility, rank, reported facts, expert decisions,
source history and the 10-MiB searched-text rule stay unchanged. Full native
`CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 9m5.30s: native style/security/eager
loading clean, 431 Rails tests / 5982 assertions and 44 browser tests / 2023
assertions, no failures/errors/skips. The byte check still follows association loading; avoiding unused
retained payloads and stronger byte-read preflight remain independent engineering
work, not customer pilot gates. No schema, provider, data, dependency or label.

Slices 48–51 are pushed as open stacked PRs
[#188](https://github.com/glnarayanan/navishai/pull/188),
[#189](https://github.com/glnarayanan/navishai/pull/189),
[#190](https://github.com/glnarayanan/navishai/pull/190) and
[#191](https://github.com/glnarayanan/navishai/pull/191). At 15:44 UTC on 1 October,
#190 passed exact-head run
[36884566317](https://github.com/glnarayanan/navishai/actions/runs/36884566317),
completed 15:42:35 UTC. #188/#189/#191 and #187 still ran `bin/ci` with no conclusion.
Running-job log requests were unavailable (CLI refused; API returned BlobNotFound).
No internal step or cause is established. Failed #155/#158 runs remain failed. No PR was merged,
released or deployed; the owner-owned lockfile stays unstaged and unchanged.

## Projected matching inputs (slice 53)

Two red tests reproduced unused contract reads and a real UTF-8 corpus exceeding
10 MiB after full candidate/source/evidence rows loaded. Matching now reads SQL
byte lengths and source/review links first, with the same eligibility and ordered
overflowing-prefix bytes. Only then does it load searched text, typed known facts
and searched quotes. Native scoped preloading omits source content/context, hidden
facts, requirements, selection reasons, review notes and ignored quote text.
Every evidence ID/source remains for fresh decision checks. Returned records are
read projections; complete definitions remain on their fixed version/source pages.
Stored evidence and full permitted-knowledge reads stay unchanged.

The initial focused checks passed 16 tests / 168 assertions with native style clean.
The final tests also check the exact joined UTF-8 byte edge, independent permitted
knowledge expectations and stale-knowledge refusal on a projected candidate.
Final `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passed in 7m40.38s: native style/security
audits/eager loading clean, 434 Rails tests / 6030 assertions and 44 browser tests /
2023 assertions, no failures/errors/skips. Existing matching/revision/regression
journeys pass; final desktop/390px conflict/history captures show unchanged exact
links, typed facts, review status and intact controls. The empty reason field after
successful append is intentional, not missing data. No appearance, definition, label, rank, schema, provider or
dependency changed. This closes the prior count/text/body overread findings;
it does not prove semantic retrieval, arbitrary-metadata memory or customer quality.

Slice 52 is committed/pushed as open
[#192](https://github.com/glnarayanan/navishai/pull/192), stacked on #191.
At 16:04 UTC, #187/#188/#189/#191/#192 remained in progress at their exact heads;
#190 remained green. Earlier failed #155/#158 runs remain failed. No remote
rerun/cancellation, merge, release, deployment or live disclosure/spend occurred.

## Typed scenario mutations (slice 54)

Real red tests reproduced a refused integer-to-float variant and a type-only
revision silently treated as unchanged. PostgreSQL retains both JSON types,
including nested facts and mutation evidence. Two native `eql?` comparisons now
preserve those changes, unordered objects, ordered arrays and null/false values.
Parents, sources, reasons and prior approvals stay fixed. Variants still require
expert revision and explicit review; no expected behaviour is inferred.

Native style and eager loading pass. Scenario/compiler/evaluation checks pass
29 tests / 428 assertions. These checks prove retained definitions, not whether a
numeric type change matters to a customer's support policy. No dependency changed.

Slice 53 is committed/pushed as open
[#193](https://github.com/glnarayanan/navishai/pull/193), stacked on #192.
At 16:14 UTC, #193 and #187–189/#191–192 remained in progress; #190 was green.
Earlier failed #155/#158 runs remain failed. No merge/release/deployment occurred.

## Authored retrieval evidence (slice 55)

Seven synthetic tests specify exact intended identities and literal ranks without
using matcher scores to derive expectations. Real intake/scenario APIs expose
diagnosis-versus-symptom ranking, conflicting facts, negation, facts-only overlap,
top-five displacement, paraphrase misses and unrelated document vocabulary.
Trace corrections/outputs, trace expectation quotes and knowledge quotes do not
enter matching. Retrieval writes no decisions, reviews or audit events.

Native style passes; the matrix and existing matching checks pass 17 tests /
190 assertions. This proves method behaviour, including deliberate misses, not
semantic retrieval quality, expert truth or customer coverage. No algorithm,
label, approval, provider call or dependency changed. Meaningful matching remains
an engineering/quality gap; it is not made complete by these fixture assertions.

## Complete calibration accounting (slice 56)

An overlapping-state red test exposed missing unlabelled accounting. Reports now
count pass/fail/abstain/error/missing predictions across the whole selected cohort,
separately from the mutually exclusive reasons that exclude a sample. Compared
samples plus exclusions equal the cohort size. Disputes and uncertainty still
cannot supply truth; resolving a label dispute never rewrites a prediction.
Original and revised development graders have separate tallies and unchanged
confusion/cost rules, first-label hiding and held-out boundaries.

Focused calibration checks pass 17 tests / 174 assertions before two additional
preview-tally assertions. `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 9m11.72s:
445 Rails tests / 6233 assertions and 45 browser tests / 2059 assertions, no
failures/errors/skips. Native style/audits/eager loading pass.
The first browser run passed its UI assertions but failed on an unsupported
Capybara element screenshot method; that run is not green evidence. Initial mobile
element crops also clipped warnings. Reusing the existing full-viewport Chrome
capture fixes the artifact; the final capture-only adjustment passes native style
and the focused browser check (1 test / 36 assertions). Inspected final desktop/
390px mixed and empty states show complete readable counts, unknowns and warnings.
No provider, label, approval, schema or dependency changed.

## Explicit expert scenario selection (slice 57)

The retrieval matrix exposed a real UI gap: association writes already accepted
eligible versions outside five suggestions, but the page offered only those five.
A scoped, read-only #ID lookup now opens one chosen current scenario for the trace.
Writers reuse the existing reasoned decision and trace-evidence editor; viewers
only inspect. Foreign IDs reveal no title. Rejected/stale choices get no decision
form. Failed stale writes retain the original version and reason, never transfer
them to a newer version, and require explicit reselection.

The red lookup test failed before the UI existed. Native style, 16 access/model
checks / 216 assertions and three browser journeys / 171 assertions pass. Final
desktop/390px selection, stale recovery and exact trace-editor captures were
inspected. Selected inputs and full trace/source links remain readable; long native
picker options may truncate, with the full identity shown separately. No rank,
approval, expectation, label, provider, schema or dependency change follows a GET.

Slices 54–56 are committed/pushed as open stacked
[#194](https://github.com/glnarayanan/navishai/pull/194),
[#195](https://github.com/glnarayanan/navishai/pull/195) and
[#196](https://github.com/glnarayanan/navishai/pull/196). Remote CI is separate from
the combined local proof. No merge/release/deployment or live disclosure occurred.

## Typed nested matching facts (slice 58)

A real intake/storage red test exposed recursive numeric coercion: matching
called a nested integer and float equal, then ranked an older conflicting version
ahead of exact facts. Recursive `eql?` now retains those types, without changing
object-key ordering, shared terms, thresholds, evidence or expert authority.
Browser checks show trace 0.0 versus scenario 0 as a conflict, not an equal fact.
No association or approval follows retrieval.

Focused matching/retrieval/scenario checks pass 31 tests / 444 assertions and the
new browser journey passes 1 test / 18 assertions. Desktop/390px conflict captures
were inspected. Combined `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 9m13.67s:
449 Rails tests / 6310 assertions, 47 browser tests / 2136 assertions, no failures,
errors or skips. Native style, audits and eager loading pass. Slices 57–58 are
committed/pushed as open stacked
[#197](https://github.com/glnarayanan/navishai/pull/197) and
[#198](https://github.com/glnarayanan/navishai/pull/198).
No merge/release/deployment occurred.

## Varied large-input proof (slice 59)

Real bounded JSONL intake now has a 99,998-conversation proof across twenty uneven
author-known term families, plus two documents: exactly 100,000 fixed inputs.
Four surface variants, shared integration words and Unicode/HTML supplement the
earlier repetitive scale test. Replacing current intake cannot change any of the
fixed historical members, exact partitions or 22 selected records. Two late risk
records retain signals beyond the 4000-character term window. Document gaps,
historical source-backed unapproved mining and repeat-job/mining idempotence pass.
The actual discovery job materializes no complete CorpusItem objects.

`bin/rails test test/services/varied_corpus_discovery_test.rb` passes both proofs:
2 tests / 426 assertions, no failures/errors/skips; 3m30.78s and 406792 KiB peak
RSS for that whole command in this orb. Native style and diff checks pass.
This is synthetic method/resource evidence, not semantic taxonomy, customer
coverage or arbitrary-corpus throughput. No production code, bounds, source
rights, labels, provider calls or dependencies changed.
Combined `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 12m1.99s: 450 Rails tests /
6596 assertions and 47 browser tests / 2136 assertions, no failures/errors/skips.
Native style, audits and eager loading pass; whole-command peak RSS is 513640 KiB.

At 17:15 UTC on 1 October, exact-head remote CI for #190 and #195 is green.
#187–189, #191–194 and #196–198 remain in progress without a conclusion.
The #196 run reports `bin/ci` in progress and does not yet expose its logs;
no cause is established. Earlier #155/#158 failures remain failures. Nothing was
cancelled, rerun, merged, released or deployed.

Slice 59 is committed/pushed as open stacked
[#199](https://github.com/glnarayanan/navishai/pull/199), based on #198.

## Exact expert lookup (slice 60)

A real GET red test proved that Rails cast a decimal input to an existing integer
scenario ID. The lookup now accepts one bounded digit string before querying.
Decimals, exponents, suffixes and parameter collections cannot open another
scenario or supply its decision form. Whole IDs still use the same corpus scope,
fresh eligibility and separate expert decisions.

Focused access checks pass 7 tests / 150 assertions. All integration checks pass
112 tests / 2171 assertions. All rendered browser journeys pass 47 tests /
2142 assertions, no failures/errors/skips. The native number field retains an
exponent value on GET but offers no decision form; replacing it with the whole ID
opens the intended version and completes the existing expert workflow. Native
style, eager loading and Brakeman pass (zero warnings/errors). No appearance,
labels, approvals, provider calls, schema or dependency changed.

Slice 60 is committed/pushed as open stacked
[#200](https://github.com/glnarayanan/navishai/pull/200), based on #199.

## Skip unused matching facts (slice 61)

A red test observed unused large fact JSON being tokenized for versions with zero
or one shared term. Those versions now skip that work: excluding fact words can
never increase overlap. The second threshold still excludes account-only matches;
full searched membership, ordering, evidence, refusal bounds and decisions stay
unchanged. The test checks actual tokenization inputs and one still-required fact
check, not a timing threshold. Its initial raw-JSON assertion failed on object-key
ordering; comparing parsed inputs fixes that test without changing production.

Matching, authored retrieval and scenario checks pass 32 tests / 453 assertions.
Combined `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 10m7.15s: 452 Rails tests /
6645 assertions and 47 browser tests / 2142 assertions, no failures/errors/skips.
Native style, audits and eager loading pass; whole-command peak RSS is 534344 KiB.
No semantic-quality, arbitrary-throughput, label or provider claim follows.

## Local scenario lookup (slice 62)

The scenario list now searches current title, situation and taxonomy with one
private literal phrase. Facts, requirements, source quotes, selection reasons
and old versions stay outside lookup. Corpus-locked counts and fifty-row metadata
reads keep complete filter totals, stable IDs and existing review/merge/stale states.
Viewers remain read-only. Typed Rails binds filter private phrases in request and
SQL-debug logs; URLs/history still retain them. Invalid input returns 422 with
retained text, an accessible repair alert and no partial rows.

Focused access checks pass 12 tests / 255 assertions, including literal wildcard,
Unicode, whole-count paging, tenant/role/expiry, route safety and actual DEBUG-log
and projection checks. Rendered scenario journeys pass 2 tests / 76 assertions.
Desktop/390px all, matched, empty and invalid states were inspected; browser checks
prove Enter, full input retention, clear recovery, ARIA and no overflow/CSP issues.
The first integration attempt had two test-framework errors, not product failures;
corrected native assertions and timestamp-bind inspection now pass.
No rank, expert decision, schema, dependency, provider or customer data changed.
Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 12m17.69s: 458 Rails tests /
6824 assertions and 48 browser tests / 2191 assertions, no failures/errors/skips.
302 Ruby files, native security audits and eager loading pass; whole-command peak
RSS is 555724 KiB. Direct risk review used; named review tools remain unavailable.

At 18:16–18:18 UTC on 1 October, exact-head remote CI for #190, #195 and #199
is green; the other twelve PRs in #187–201 remain inside `bin/ci` with no conclusion.
Runner/container/checkout/Ruby setup passed for each. #187 and #196 expose neither
active logs nor artifacts, so the internal command and cause remain unknown.
Completed GitHub suites took 12–18 minutes overall; size alone does not explain
multi-hour runs. Nothing was cancelled, rerun, merged, released or deployed.
Earlier failed #155/#158 runs remain failed.

## Searchable company evidence (slice 63)

The scenario editor previously offered only the first hundred current documents,
although its revision API accepted later eligible records. A red request test
reproduced the missing rendered path. A private literal document filter now counts
all same-corpus current matches and loads only a hundred IDs/titles for selection.
It excludes context, conversations, stale snapshots and expired/foreign sources.
The separate GET warns experts to save edits first; it selects no evidence, copies
no excerpt and changes no version, approval, label or job. Failed edits keep their
filter, explicit choice and expert text. Selected traces survive filtering/clear.

Focused access checks pass 16 tests / 385 assertions. Actual intake of 102 synthetic
documents proves the original window, late match, exact quote attachment and an
unapproved new version. Other checks cover literal wildcards and Unicode,
privacy-filtered DEBUG binds, metadata-only projection, scope/expiry, repair,
invalid search and edit together, and trace retention. Rendered scenario
journeys pass 3 tests / 125 assertions, with keyboard Enter, explicit selection,
invalid excerpt repair, empty/error/clear recovery and no overflow/CSP violations.
Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 10m45.77s: 462 Rails tests /
6954 assertions and 49 browser tests / 2240 assertions, no failures/errors/skips.
302 Ruby files, native security audits and eager loading pass; whole-command peak
RSS is 546216 KiB. Direct risk review used; named review tools remain unavailable.
Final inspection found inherited mobile emulation in some desktop captures.
Scenario journeys now clear that state and wait/assert the actual requested width;
an explicit inherited-emulation fixture checks the repair. Application code stayed
unchanged. Final `CAPTURE_LAB_SCREENSHOTS=1 bin/rails test:system` passes 49 tests /
2258 assertions, no failures/errors/skips. Corrected desktop/390px lookup, picker,
empty and invalid crops were inspected; native style and diff checks pass.
No production dependency, schema, provider, customer data or expert label changed.

At 18:47 UTC on 1 October, #190/#195/#199 remain exact-head remote green.
The other thirteen PRs in #187–202 remain in progress without a conclusion,
including [#202's run](https://github.com/glnarayanan/navishai/actions/runs/36906946939).
The prior log/step investigation still establishes no cause. No remote action
changed those jobs, and earlier #155/#158 failures remain failed.

## Corpus-relative failure ranking (slice 64)

A red authored test reproduced a raw-count miss: seven common symptom candidates
displaced a two-term diagnostic candidate. Literal retrieval now sums distinct
shared-term rarity across all eligible searched current definitions, then uses
equal facts and version ID for ties. It reuses local discovery's inverse-frequency
weighting; repeated words cannot boost the score. Scope, freshness, byte/count
refusal and explicit expert associations stay unchanged. Scores grant no authority.

Focused service checks pass 21 tests / 267 assertions. Independent eight-definition
counts verify score/contributions, query and definition repetition, historical and
rejected versions, and unmatched denominator members. Existing scope, typed facts,
metadata projections, real 2000-version and UTF-8 byte bounds still pass. The seven
earlier retrieval limits still reproduce, including negation, paraphrase misses,
symptom displacement and irrelevant expectation vocabulary. No customer quality,
coverage or accuracy claim follows this ranking change.

Rendered journeys pass 5 tests / 223 assertions. Keyboard Enter opens/closes
**Why this rank?**; rounded term contributions and membership-dependent score
limits stay visible without a confidence percentage. Desktop/390px captures were
inspected; overflow and CSP checks pass. Original association/revision/regression,
viewer, empty and stale-repair paths pass. Native style passes for 302 Ruby files.
Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 9m50.49s: 464 Rails tests /
7008 assertions and 50 browser tests / 2286 assertions, no failures/errors/skips.
Native security audits and eager loading pass; whole-command peak RSS is
541940 KiB. Direct risk review used; named review tools remain unavailable.
No schema, dependency, provider, customer data or expert label changed.

At 19:07–19:09 UTC on 1 October, #190/#195/#199 remain exact-head remote green;
the other fourteen PRs in #187–203 remain in progress inside `bin/ci`. Each running
job's runner/container/checkout/Ruby setup passed, but every active-log request returns BlobNotFound and
every artifact list is empty. No current failure cause is known. Historical #155
failed a calibration-report browser assertion; #158 failed a corpus-search browser
assertion. Later synchronization/cache changes address those paths, but neither
old failure explains today's opaque running jobs. No remote job was changed.

## Complete-text local discovery (slice 65)

Both older local versions clustered titles plus the first 4000 conversation
characters. A separate explicit v3 now includes complete conversation text within
the original 2000-record / 10-MiB bound. It preserves global frequencies, ordered
seeds, threshold, risk priority and expert authority. Existing term-entry,
vocabulary and comparison budgets fail atomically. No source inputs, historical
v1/v2 windows/results or mining approvals change.

Focused service/access checks pass 17 tests / 280 assertions. Long asymmetric
conversations share a preamble but have distinct late diagnostics: full text
separates them; both older methods retain their original shared cluster. Fixed
historical membership, exact budget boundaries and one-below failures, repeated
job refusal, immutable method identity, unapproved mining, local-only configuration,
disclosure refusal, writer/foreign/viewer checks and method-preserving repair pass.
These authored records test engineering, not real-company taxonomy quality.

Rendered journeys pass 3 tests / 195 assertions, covering explicit keyboard
selection, queued local-only disclosure, complete late-term families, unapproved
scenario mining and a budget failure with no partial proposals or retry. Desktop
and 390px picker/queued/complete/failed captures were inspected; actual width,
overflow and CSP checks pass. Native style passes for 302 Ruby files.
Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in 11m9.22s: 468 Rails tests /
7121 assertions and 51 browser tests / 2355 assertions, no failures/errors/skips.
Native security audits and eager loading pass; whole-command peak RSS is
455456 KiB. Direct risk review used; named review tools remain unavailable.
No schema, dependency, model/provider, customer data or expert label changed.

## Expert conversation evidence repair (slice 66)

Mining retained the first 4000 source characters, and the revision path could not
replace them with later evidence from the same conversation. Experts now have a
separate expectation-only exact-quote field tied to that fixed record/snapshot.
Changing it creates an unapproved version without changing target input, facts or
requirements. Blank/identical saves remain no-ops; other evidence, past approvals
and compiled cases stay fixed. No broader source picker or automatic extraction.

Focused model/access/compiler checks pass 41 tests / 836 assertions. They distinguish
late retained diagnostics from a newer export, preserve knowledge and visible input,
check 1/4000/4001 Unicode-character bounds, reject invented/other-record quotes and
non-text, and prove atomic attachment rollback, scope, viewer, stale and expiry
guards. Fresh approval and fresh check bindings precede compilation; old cases keep
their original quotes. The existing private-field filter also covers the new field.

Rendered journeys pass 4 tests / 204 assertions. Keyboard disclosure, invalid-quote
repair and saved hidden evidence pass at desktop/390px, with actual viewport-width,
overflow and CSP checks. All six edit/error/saved crops were inspected. Native
style passes 302 Ruby files. Full `CAPTURE_LAB_SCREENSHOTS=1 bin/ci` passes in
9m17.28s: 473 Rails tests / 7246 assertions and 52 browser tests / 2416 assertions,
no failures/errors/skips. Native security audits and eager loading pass; whole-command
peak RSS is 563108 KiB. Direct risk review used; named review tools remain unavailable.
No schema, dependency, provider, customer data or authoritative expert label changed.

At 19:55–19:56 UTC on 1 October, all nineteen CI runs for #187–205 match their PR
heads: #190/#195/#199 are green and sixteen remain inside `bin/ci`. Each active
job passed runner/container/checkout/Ruby setup, but all active log requests return
BlobNotFound and all artifact lists are empty. No exact-head failed run or current
cause was available then. No remote job changed; historical #155/#158 remain separate.

## Bounded mined labels (slice 67)

A red Unicode boundary test reproduced an overlong taxonomy label rolling back
the draft batch. Mining now shortens only new labels above 500 characters, keeps
the complete proposal/source/quote and explains the change. Repeated mining or
nomination opens the existing expert revision without changing decisions.
Actual DEBUG INSERT logs also proved label disclosure; the native field filter
now covers taxonomy labels without changing retained content.

Focused model/access/compiler checks pass 43 tests / 886 assertions. Five rendered
scenario journeys pass 242 assertions, including first nomination and source
inspection. The long ASCII family exposed horizontal heading overflow; text now
wraps at desktop and 390px. Four targeted captures were inspected; the mobile
family crop cuts the button's bottom border, not its visible label. Executed DOM
checks confirm intact links, no horizontal overflow and no CSP violations.
Native style, audits and eager loading pass. Full combined CI remains separate.
Direct risk review used; named review tools remain unavailable. No provider,
dependency, expert label, customer data, merge, release or deployment changed.

At 20:23–20:24 UTC on 1 October, #190/#195/#199 remain exact-head green.
#187's run [36875739393](https://github.com/glnarayanan/navishai/actions/runs/36875739393)
was cancelled at 20:22:22: GitHub explicitly reports its six-hour maximum.
Its now-available log stops during 419 Rails tests / four processes, without an
assertion failure or result summary. Sixteen other heads #188–206 still run.
#206's active log remains unavailable and artifacts remain empty. The timeout
is confirmed; its code cause is not. No remote job was cancelled or rerun here.

## Private definitions and receipts (slice 68)

Actual DEBUG writes reproduced private requirement disclosure. The shared native
filter now covers titles, requirements, follow-ups, mutations, proposed/reviewed
labels, signals, fixed input/results and per-check decisions. Stored values remain
exact. Tests exercise scenario/variant/taxonomy writes, typed PostgreSQL binds for
14 actual model fields and real taxonomy request parameter logs, including ignored
private root parameters. Public method/count metadata remains visible.

Full native CI passed 477 Rails tests / 7366 assertions and 53 browser tests / 2454
assertions before the final request-log regression. The final Rails state then
passed 478 tests / 7414 assertions, with no failures, errors or skips. That run took
7m03.72s and peaked at 525176 KiB; the prior complete CI took 10m36.79s and peaked at
560008 KiB. Ruby style, audits and eager loading pass. No UI behavior changed.
Direct risk review used; named review tools remain unavailable. These filters do
not sanitize SQL literals, PostgreSQL/proxy/operator logs or arbitrary output.
No dependency, provider, customer data, expert decision, merge or deployment changed.

At 21:05 UTC on 1 October, #190/#195/#199 remain exact-head green and #187 retains
its confirmed six-hour timeout. The seventeen other heads #188–207 still run;
#207 is [run 36922246175](https://github.com/glnarayanan/navishai/actions/runs/36922246175).
No new assertion failure or confirmed code cause was available. No remote run changed.

## Original scope and landing integration (slices 69–70)

[REBUILD_ACCEPTANCE.md](./REBUILD_ACCEPTANCE.md) maps the whole original prompt,
not a smaller baseline or an agent percentage. Its inspected snapshot is slice 67;
103 local links resolve. Later integration evidence belongs here until the final
checklist closes each unblocked row. Phase F/P2 still requires real permitted labels
and measured economics, as the original prompt states.

The public page now explains company corpus, expert scenarios, compiled checks,
calibration, failures and regressions. The SSO example is explicitly illustrative.
Privacy copy states masking, disclosure, deletion, reported-action and quality
limits. Real sign-in and bootstrap availability remain; signed-in root still opens
workspaces. No customer claims, pricing, live integrations or domain writes appear.

Integrated native CI passed setup, Ruby style, audits, eager loading and 481 Rails
tests / 7465 assertions. Its browser stage found one stale logout assertion for the
old placeholder. The assertion now checks the public sign-in route, not discarded
copy. The final complete browser run passed 56 tests / 2600 assertions with no
failures, errors or skips; focused auth checks passed 15 / 150. Ruby style passes
305 files. The initially failed CI run remains a failed run, not a green command.

Inspected full 2x desktop/light and 390px/dark pages show the complete workflow,
SSO example, privacy and footer without clipping. Executed DOM checks confirm six
steps, the real sign-in URL, 16px narrow body text and no horizontal overflow.
Native browser tests cover 1280/768/390/320px, both themes, keyboard disclosures,
anchors, focus, auth and CSP. Worker captures also cover signed-in and expanded
FAQ states. See [LANDING.md](./LANDING.md). Direct review used; named review tools
remain unavailable. No merge, release, deployment, provider or customer action ran.

## Private source identities (slice 71)

Real DEBUG intake and lookup tests reproduced source-name and external-record-ID
disclosure. The shared field filter now hides both in request parameters and SQL
binds without changing stored identities or content. Actual intake, lookup, typed
bind and ignored-root-parameter tests retain exact values; public method/count
metadata and content-free audit actions stay visible.

`PARALLEL_WORKERS=1 bin/rails test test/integration test/controllers
test/services/corpus_intake_test.rb` passes 191 tests / 3593 assertions, no failures,
errors or skips. Ruby style passes 305 files, eager loading passes and Brakeman
reports zero warnings/errors. A test-only audit lookup initially used a nonexistent
association; the final test uses the stored subject type/ID. Direct risk review
used; named review tools remain unavailable. The owner lockfile stays untouched.
These filters do not cover SQL literals or database/proxy/operator logs. No UI,
provider, dependency, live data, expert decision or deployment changed.

## Fixed-input query plan (slice 72)

Committed intake, source purge and a later intake can leave PostgreSQL with empty
row estimates on retained pages. The frozen-membership join then chooses a
quadratic nested loop, affecting expiry checks as well as record/byte counts.
An indexed correlated existence check now serves all frozen-input readers, with
explicit workspace/corpus scope. Count/byte limits, history, expiry and purge stay
unchanged. No fixture ANALYZE workaround, timeout increase or removed guard.

The parent checkout passed `PARALLEL_WORKERS=4 bin/rails test --seed 44664`:
483 tests / 7500 assertions, no failures, errors or skips, in 661.485 seconds.
The complete browser suite on a separate disposable database passed 56 tests /
2600 assertions, no failures, errors or skips. Ruby style passed 306 files and
eager loading passed. The worker's before/after native regression and committed
20,000-record replay are in [CI_TIMEOUT.md](./CI_TIMEOUT.md). The historical
remote #187 timeout remains unattributed: its log contains no query or stack
snapshot. No remote job, infrastructure, provider or dependency changed.

## Large complete-text local processing (slice 73)

Explicit v4 processes complete conversations within 100,000 records / 1 GiB,
using the existing global weighting and fail-atomic work caps. Original, streaming
and smaller full-text methods keep their fixed versions and windows. Evidence
reads and mining remain bounded to 10 MiB. No model call or new schema follows.

Parent request/access/lifecycle checks passed 7 tests / 189 assertions, and native
desktop/mobile journeys passed 5 / 326, with no failures, errors or skips.
Integrated desktop complete and mobile selected states were rendered and inspected;
keyboard selection, actual widths, CSP and overflow checks passed. Ruby style
passed 310 files, eager loading passed, Brakeman reported zero warnings/errors,
and gem/importmap audits passed. [LARGE_FULL_TEXT.md](./LARGE_FULL_TEXT.md) records
the worker's 47 / 1368 checks, including both 100,000-input proofs. Final combined
scale/runtime checks remain pending while the other assigned slices join.

## Source review drafts and controlled variants (slice 74)

Local mining now proposes a bounded opening and cue-rich source review, not raw
context or action sentences as facts/expectations. Source offsets and questions
remain proposals. Structured extraction preserves supplied starting facts and
refuses invented hidden facts. Experts still write and review expected outcomes.
Variants change 1–5 named facts, retain exact parents/before-after values and clear
expectations, hidden facts and follow-ups. Fresh expert revision/review is required.

Parent focused and adjacent checks passed 70 tests / 1579 assertions; browser
journeys passed 12 / 543, with no failures, errors or skips. An initial integration
run caught a privacy test that relied on copied source facts. The test now authors
its fact in the expert revision; no product guard was weakened. Desktop source
questions and mobile repair/coupled receipts were rendered and inspected. Ruby
style passed 314 files, eager loading passed and Brakeman reported zero warnings
or errors. Both additive migrations ran in development and isolated test schemas;
the native schema dump matches them. See [SCENARIO_QUALITY.md](./SCENARIO_QUALITY.md)
for the worker's broader 100 / 1868 checks and literal-method limits. No live
model, training, customer-quality or semantic-coverage claim follows.

## Source-backed support observations (slice 75)

Explicit single/batch v2 choices retain source-backed support distinctions with
proposed status, required uncertainty and all exact anchors, independently of
selected scenarios. V1 defaults and meanings stay fixed. Preview, request and
processing rechecks bind the versioned batch plan. Existing once-only jobs and
publication transactions apply; no extra calls, receipt tables or expert writes.
The reducer preserves/orders originals and cannot create cross-batch relationships.

Parent focused/adjacent checks passed 48 tests / 877 assertions, including native
v2 registration without worker substitutes, actual request/job execution, wrong
plan refusal, revocation, fixed history, expiry/purge and v1 inspection. Browser
journeys passed 4 / 184 with keyboard consent/source links, desktop/mobile quotes,
repair, empty and stopped results. All four result anchors and uncertainty were
rendered and inspected; native CSP and overflow checks passed. Earlier test-only
helper/snapshot assumptions failed and were corrected without changing product
guards. Ruby style passed 316 files, eager loading passed, Brakeman reported zero
warnings/errors and dependency/importmap audits passed. See
[MODEL_CORPUS_OBSERVATIONS.md](./MODEL_CORPUS_OBSERVATIONS.md). Fixtures prove
retention/contracts, not company-wide semantic understanding or model quality.

## Next and limits

The P0 engineering loop passes with fixtures. Phase E now includes trace-to-reviewed
regression, exact source-change impact and fixed-case target-version comparison.
Corpus exploration now has bounded, source-backed literal search.
The scenario list offers private current-definition lookup for expert selection.
Company-document lookup now reaches beyond the initial evidence-picker window.
Expert calibration now has a personal read-only review queue.
This does not finish the full rebuild or establish customer value. Trace failure
matching now suggests five local literal candidates from up to 2000 current
versions using corpus-relative term rarity, with explicit expert associations;
it is not semantic matching. Negation and zero-overlap paraphrases remain unresolved.
Replay compatibility now searches all fixed cases and paginates exact matches. Recorded
replay uses one fixed output and cannot answer unrelated cases. Customer acceptance still needs a
privacy-approved, previously unseen technical-Support dataset,
authoritative expert corrections and approved target/judge/source-processing endpoints.
The endpoint registries have no configured entries. Original local analysis keeps
2000 records / 10 MiB; explicit streaming local accepts 100,000 / 1 GiB within
its resource budgets, with complete reads still bounded to 10 MiB.
Explicit full-text local covers complete conversations within 2000 / 10 MiB and
the same computation budgets; the older methods keep their 4000-character window.
Model corpus discovery proposes company families and
structured source-backed scenarios from complete fixed records: one request within
100 records / 256 KiB, or bounded multi-request discovery within 2000 records /
10 MiB and 31 total calls. It does not silently sample larger inputs. Local mining still uses titles/context/
sentences. Neither model discovery nor single-scenario proposals grant approval.
Experts check source-backed outcomes. Controlled variants
need an expert revision before approval. Changed documents flag stale evidence;
new snapshots replace evidence only in new versions. Source purge deletes scenarios
and descendants because their analysis depends on the full corpus. Purge also
clears fixed cases, corpus graders/calibration, targets, runs/results and regressions;
suite names remain without cases. Judges execute through a generic gateway;
the gateway must enforce model/settings and separate data from instructions.
Fixture responses do not establish grader accuracy.
Continuous-learning P1 follows a proved P0 loop; classifiers remain gated by labels
and economics. Fixture checks do not establish discovery quality or judge accuracy.

Connected fresh revised-judge calibration, matched-trace → existing-scenario
evidence revision, family-level source-signal counts/drill-down and private Compose
ingress/control/edge proof now pass. Optional expert-supplied calibration error-cost
assumptions and report-local judge-threshold disclosure also pass.
Public ingress/egress/deny-policy and clean-host acceptance still need a suitable
authorised host; private namespace probes cannot establish them.
Reviewable failure matching, bounded multi-request discovery, image execution and
isolated backup/restore/private production-runtime/TLS checks pass; inputs beyond those bounds and retrieval
quality need further evidence, not a coverage claim. Keep the full product scope;
engineering gaps are not customer-data or expert-label approval blockers.
Intake now refuses recursive masking-key collisions without losing data and binds
processing version and explicit rule fingerprints in snapshot reuse identity.
Exact-text masking and larger local processing work within their stated limits.
Normalized conversation JSONL accepts 100,000 records / 60 MiB per file; other
formats stay at 2000 / 10 MiB. Varied-workload and larger-file checks now supplement
the repetitive scale proof, including a heterogeneous 100,000-input journey.
Broader workload evidence and retrieval quality still
need engineering work; these checks do not finish the owner's full acceptance demo.
Local scenario context extraction remains title/context/action based, with bounded
first-source excerpts. Experts can now replace their own fixed conversation quote
with later diagnostics, but this does not fix automatic draft-quality gaps.
New mined labels now respect the 500-character limit without changing full source
proposals or saved expert decisions. Private definition/result fields now pass
actual native request/SQL log-filter checks; storage remains unchanged.
Larger complete-text workloads also need bounded engineering work and evidence,
not a silent increase of existing limits or a semantic-quality claim.

No real customer dataset, live model/target, SMTP/OIDC provider, training or customer
validation ran. The partial Compose trial and later passing private-namespace proof
do not establish clean-host, public ingress/useful-egress, public TLS or production
backup acceptance.
Pinned-image execution and isolated runtime roles pass, not deployment acceptance. Database administrators can
bypass triggers; last-Owner protection is application-side. Backups need their own
retention policy. See [development](./DEVELOPMENT.md), [security](./SECURITY.md),
[deployment](./DEPLOYMENT.md) and [design](./DESIGN.md).

The user-owned Bundler checksum in Gemfile.lock remains unstaged and outside the
rebuild commits. Phase A removed obsolete gems and capped JSON below 3 after tests
proved JSON 3 incompatible with this Rails version. No new dependency was added.

## Pending owner decisions

1. Approve rights, redaction and retention for a previously unseen technical-Support
   pilot corpus. No customer data has been imported or disclosed.
2. Name the authoritative pilot experts and obtain their expectations/held-out
   labels. Fixture judgments cannot establish taxonomy quality or grader accuracy.
3. Approve exact target/judge/scenario/corpus-processing endpoints, disclosure scope
   and cost limits before live execution. The private registries still have zero entries.
4. Provide or authorise a disposable clean host with authority over proxy/network
   testing if no runner can supply it. The runner list remains empty at the slice-63
   check on 1 October. Private Compose ingress now passes; public ingress, useful-egress
   and deny-policy proof remain unfinished. The removed trial's exact failure
   cause remains unverified despite the controlled userland-proxy reproduction.

Classifier work remains gated by enough labelled data and measured economics.
Independent local engineering and fixture checks can continue without these gates.
