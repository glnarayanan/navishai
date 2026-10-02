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
- `rebuild/45-bounded-analysis-review`, based on #184: bounded fixed-record reads,
  typed family counts and complete-text scalar batches without full-corpus loading.

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

## Next and limits

The P0 engineering loop passes with fixtures. Phase E now includes trace-to-reviewed
regression, exact source-change impact and fixed-case target-version comparison.
Corpus exploration now has bounded, source-backed literal search.
Expert calibration now has a personal read-only review queue.
This does not finish the full rebuild or establish customer value. Trace failure
matching now suggests five local literal candidates from up to 2000 current
versions, with explicit expert associations; it is not semantic matching.
Replay compatibility now searches all fixed cases and paginates exact matches. Recorded
replay uses one fixed output and cannot answer unrelated cases. Customer acceptance still needs a
privacy-approved, previously unseen technical-Support dataset,
authoritative expert corrections and approved target/judge/source-processing endpoints.
The endpoint registries have no configured entries. Local analysis remains bounded
to 2000 records and 10 MiB. Model corpus discovery proposes company families and
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
Exact-text masking works within its stated limits; larger-corpus processing and
streamed processing beyond the current analysis bounds remain engineering work.
These checks do not finish that work or the owner's full acceptance demo.

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
   testing if no runner can supply it. The runner list was empty at 04:46 UTC on
   1 October. Private Compose ingress now passes; public ingress, useful-egress
   and deny-policy proof remain unfinished. The removed trial's exact failure
   cause remains unverified despite the controlled userland-proxy reproduction.

Classifier work remains gated by enough labelled data and measured economics.
Independent local engineering and fixture checks can continue without these gates.
