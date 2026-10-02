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
- `rebuild/24-production-boundary`, based on #163: separate preparation/runtime
  database roles, explicit schema preparation and disposable production-runtime proof.

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

## Next and limits

The P0 engineering loop passes with fixtures. Phase E now includes trace-to-reviewed
regression, exact source-change impact and fixed-case target-version comparison.
Corpus exploration now has bounded, source-backed literal search.
Expert calibration now has a personal read-only review queue.
This does not finish the full rebuild or establish customer value. Trace failure
matching now suggests five local literal candidates from up to 2000 current
versions, with explicit expert associations; it is not semantic matching.
Replay compatibility still checks identical inputs among 100 fixed cases. Recorded
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

Independent engineering includes executable multi-turn cases, source export,
connected result-to-calibration improvement and clean-host/Compose/egress proof.
Reviewable failure matching, bounded multi-request discovery, image execution and
isolated backup/restore/private production-runtime/TLS checks pass; inputs beyond those bounds and retrieval
quality need further evidence, not a coverage claim. Keep the full product scope;
engineering gaps are not customer-data or expert-label approval blockers.

No real customer dataset, live model/target, SMTP/OIDC provider, training or customer
validation ran. Clean-host/Compose/public TLS and production backup acceptance are unverified.
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

Classifier work remains gated by enough labelled data and measured economics.
Independent local engineering and fixture checks can continue without these gates.
