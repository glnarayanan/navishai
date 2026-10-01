# Original rebuild acceptance checklist

Updated 1 October 2026 for the joined rebuild through slice 81. The source of truth
is the owner's entire original prompt, sections 0–25 and A–F/P0–P2, in
[the source thread](https://ampcode.com/threads/T-01a0f3b9-4f9a-706a-90a2-fcee6f822501).
This map supplements [PRODUCT](./PRODUCT.md), [ARCHITECTURE](./ARCHITECTURE.md),
[DOMAIN](./DOMAIN.md), [REBUILD_PLAN](./REBUILD_PLAN.md) and [STATUS](./STATUS.md).
It supersedes the earlier exact-slice-67 gap snapshot, not the owner's scope.
The old helpdesk still lives on `origin/main`; the reviewable rebuild is a stacked
PR chain. Nothing has merged, released, deployed or received customer validation.

The owner's 1 October eight-hour correction calls for the full implementation,
security, UX, frontend, docs, marketing and non-live acceptance by about
**2 October 04:30 UTC / 10:00 Asia/Calcutta**. Only the owner's live acceptance may
remain; unavailable host/data/provider authority must stay explicit, not silently
become a completed check. No merge, deployment, paid call or customer disclosure ran.

**E** means implemented with executed engineering checks. **M** means missing
implementation or engineering evidence. **G** means evidence needs authorized data,
experts, endpoints, costs or a host. An E contract does not imply semantic quality.
The owner's example counts and percentages are illustrations, not measured claims.

This map has 45 check groups: 41 E, zero M and four G. That is 41/45 groups
(91.1%) with engineering evidence, including all 41 ungated engineering groups.
It is not a feature-count, quality or customer-acceptance score. The four G groups
remain unproved; conditional P2 below stays separately gated and is not counted
as delivered. The stack through [#222](https://github.com/glnarayanan/navishai/pull/222)
is committed, pushed and open, not merged, released or deployed.

## A — Demolition, architecture and delivery

| Check | Evidence and limit |
|---|---|
| E — Authorities before new code; retain/simplify/transform/delete inventory | [ARCHITECTURE](./ARCHITECTURE.md#inventory-and-disposition) and [the reset commit](https://github.com/glnarayanan/navishai/commit/f8200af). Rails/Hotwire/PostgreSQL/native jobs remain; no unnecessary worker language, SPA or ML service. |
| E — Remove the old product and its unused dependencies | [lab_baseline_test](../test/integration/lab_baseline_test.rb) checks old routes/tables are gone. Inbox, tickets/assignment, customer drafts/sends, SLAs, account-health/renewals, crews, broad memory/Supermemory, process runners and old deployment machinery do not remain behind flags. Git preserves history. |
| E — Re-derived tenant/source/eval domain and safe fresh setup | [database_preflight_test](../test/services/database_preflight_test.rb), [security_baseline_test](../test/integration/security_baseline_test.rb). Setup refuses obsolete databases and never resets customer data. |
| E — Atomic Conventional Commits and stacked PRs | [STATUS delivered stack](./STATUS.md#delivered-stack). Implementation branches use the rebuild predecessor, not obsolete main. The owner lockfile checksum remains unstaged and unchanged. |
| E — Final combined engineering handoff | Fresh native `bin/ci` passes in 17m48.72s: Rails 640/10520 and browser 71/3561, no failures/errors/skips; style, eager loading and audits pass. Recovery/upgrade pass with v3 receipts; image-specific Compose proof passes. The stack through #222 is pushed/open, not merged/deployed. Remote CI is separate. |

## B — Corpus and scenario foundation (all P0)

| Check | Evidence and limit |
|---|---|
| E — Workspace, practical conversation/document intake, normalized corpus, immutable snapshots, masking and provenance | [corpus_intake_test](../test/services/corpus_intake_test.rb), [streamed_corpus_intake_test](../test/services/streamed_corpus_intake_test.rb), [corpus_journey_test](../test/system/corpus_journey_test.rb). JSON/Intercom/Zendesk-shaped exports, text/Markdown and explicit JSONL; no live connector/PDF breadth promised. |
| E — Exploration, source history, literal search, exact context and pagination | [corpus_exploration_test](../test/integration/corpus_exploration_test.rb), [corpus_exploration_journey_test](../test/system/corpus_exploration_journey_test.rb). Literal search is not semantic retrieval. |
| E — Company family/taxonomy proposals, expert labels, representative/rare-risk selection and explainable counts | [corpus_discovery_test](../test/services/corpus_discovery_test.rb), [issue_clusters_test](../test/integration/issue_clusters_test.rb), [family_evidence_journey_test](../test/system/family_evidence_journey_test.rb). Full fixed members and source-signal denominators stay separate from model importance, coverage and human truth. |
| E — Source-backed support-observation contract and retention | [MODEL_CORPUS_OBSERVATIONS](./MODEL_CORPUS_OBSERVATIONS.md), [model_corpus_discovery_test](../test/services/model_corpus_discovery_test.rb), [batch_corpus_discovery_test](../test/services/batch_corpus_discovery_test.rb), [support_observations_journey_test](../test/system/support_observations_journey_test.rb). Explicit v2 preserves every exact anchor and uncertainty independent of candidate selection; v1 meanings stay fixed. |
| E — New cross-batch relationships over retained source anchors | [CROSS_BATCH_RELATIONSHIPS](./CROSS_BATCH_RELATIONSHIPS.md), [cross_batch_relationships_test](../test/services/cross_batch_relationships_test.rb), [access tests](../test/integration/cross_batch_relationships_access_test.rb), [browser journeys](../test/system/cross_batch_relationships_journey_test.rb). Explicit v3 can connect records no discovery saw together, preserves every original observation and adds no calls or authority. Unseen evidence and semantic quality remain limits. |
| E — Safer reviewable local drafts and structured extraction | [SCENARIO_QUALITY](./SCENARIO_QUALITY.md), [scenario_quality_test](../test/services/scenario_quality_test.rb), [scenario_extractor_test](../test/services/scenario_extractor_test.rb). Bounded opening/cue-rich source questions replace copied raw facts/actions; experts author starting facts and expectations. Structured proposals require fixed excerpts/quotes and supplied typed facts, not invented visible or hidden truth. |
| E — Expert approve/reject/merge/edit/relabel/importance/expectations with immutable versions | [scenario_test](../test/models/scenario_test.rb), [scenario_access_test](../test/integration/scenario_access_test.rb), [scenario_journey_test](../test/system/scenario_journey_test.rb). Every changed version needs fresh source-backed review. |
| E — Basic and coupled controlled variants (P0/P1) | [scenario_variant_test](../test/models/scenario_variant_test.rb), [SCENARIO_QUALITY](./SCENARIO_QUALITY.md). One to five expert-named facts, typed before/after, fixed parent/reason/proposed difference; expectations, hidden facts and follow-ups clear. No machine policy or inherited approval. |
| E — Larger complete-text local analysis and varied workload boundaries | [LARGE_FULL_TEXT](./LARGE_FULL_TEXT.md), [large_full_text_discovery_test](../test/services/large_full_text_discovery_test.rb), [streaming_corpus_discovery_test](../test/services/streaming_corpus_discovery_test.rb), [varied_corpus_discovery_test](../test/services/varied_corpus_discovery_test.rb). Explicit v4 processes complete 100,000 records / 1 GiB with fixed work caps; no sampling/fallback or raised model/evidence bounds. Actual 100,000/100,001 and late >10-MiB diagnostics pass. |
| G — Meaningful company taxonomy, useful drafts, correction effort and measured coverage | Authored synthetic sources and stubbed outputs prove allocation, safety and retained contracts, not sound diagnosis or broad support understanding. The unseen-company demo still needs permitted data, authoritative experts and approved execution. No count or quote proves those outcomes. |

V2 can retain issue/symptom, diagnosis/guess, troubleshooting progression,
reproduction, configuration/defect, environment/integration dependencies,
workaround/permanent/partial/false resolution, escalation/Engineering handoff,
evidence sufficiency/logs, customer/agent actions, product limitations, known issues,
incidents, entitlement/policy exceptions, documentation gaps/contradictions,
disagreement, reopen/repeated contacts and customer variants. These are proposed
support distinctions, not universal company labels. Both sides of conflicting or
reopened claims stay quoted. Local English cues do not establish their meaning.
Emerging/high-volume/rare-risk families remain source-backed proposals.

V1/v2 stay frozen: the v2 reducer only preserves/orders existing observations.
Explicit v3 closes that engineering gap with new source-quoted relationship
proposals from retained anchors in separate batches and distinct source records.
Every original remains unchanged. One batch or a repeated shared document alone
cannot supply a cross-batch relationship. This does not prove arbitrary corpus-wide
contradiction, causality, exhaustive coverage or company meaning. Relationships
whose evidence was never retained remain outside this bounded method. Authorized
unseen data, experts and live-quality checks must establish useful understanding.

## C — Eval Compiler, graders and human calibration (all P0)

| Check | Evidence and limit |
|---|---|
| E — Suites/contracts/cases freeze exact reviewed versions, evidence and all check bindings | [eval_compiler_test](../test/models/eval_compiler_test.rb): complete statement accounting, wrong-version/foreign/stale refusal and immutable history. |
| E — Deterministic tools, fields, citations, escalation, policy branch, text/order and response-scoped multi-turn checks | [deterministic_grader_test](../test/services/deterministic_grader_test.rb), [multi_turn_grader_test](../test/services/multi_turn_grader_test.rb), [http_conversation_target_test](../test/services/http_conversation_target_test.rb). Reported tools are not attested execution; literals do not prove reasoning. Expert follow-ups reach the target incrementally, never in advance. |
| E — Versioned rubric judges, exact settings/thresholds, consent and once-only attempts | [judge_grader_test](../test/services/judge_grader_test.rb), [judge_execution_test](../test/models/judge_execution_test.rb), [judge_delivery_test](../test/models/judge_delivery_test.rb). Low confidence abstains; malformed output errors. No live accuracy claim. |
| E — SME labels/corrections, disputes, blind first labels and focused review | [calibration_test](../test/models/calibration_test.rb), [calibration_review_journey_test](../test/system/calibration_review_journey_test.rb). Human history remains separate from machine decisions and imported corrections. |
| E — Confusion counts, precision/recall, agreement, thresholds and explicit FP/FN costs; safe improvement | [calibration_cost_test](../test/models/calibration_cost_test.rb), [calibration_preview_test](../test/services/calibration_preview_test.rb), [result_calibration_test](../test/models/result_calibration_test.rb). Development/held-out cohorts stay distinct; missing truth/cost stays unknown. Fresh judge revisions need fresh calibration. |
| G — Customer labels, representative held-out evidence and grader accuracy | Fixture disagreements/missed failures test reports, not customer calibration acceptance. No universal accuracy threshold was specified or invented. |

## D — Target execution, failures and regression (all P0)

| Check | Evidence and limit |
|---|---|
| E — One neutral target interface; scripted, HTTP, conversation and compatible recorded replay | [scripted_target_test](../test/services/scripted_target_test.rb), [http_target_test](../test/services/http_target_test.rb), [recorded_target_test](../test/services/recorded_target_test.rb). No vendor proliferation or arbitrary shell execution. Replay is fixed output, not a fresh response. |
| E — Frozen target/cases/inputs, bounded jobs, once-only claim and unknown outcomes | [evaluation_test](../test/models/evaluation_test.rb), [evaluation_delivery_test](../test/models/evaluation_delivery_test.rb), [http_evaluation_test](../test/models/http_evaluation_test.rb). No automatic resend after uncertain remote execution. |
| E — Failed cases, severity/importance, exact evidence, individual judge confidence and usage/cost | [evaluation_journey_test](../test/system/evaluation_journey_test.rb), [judge_journey_test](../test/system/judge_journey_test.rb). Errors/abstentions never become behavioural failure or pass. Unknown cost remains unknown. |
| E — Cross-grader behavioural failure patterns | [FAILURE_PATTERNS](./FAILURE_PATTERNS.md), [evaluation_failure_patterns_test](../test/services/evaluation_failure_patterns_test.rb), [failure_patterns_journey_test](../test/system/failure_patterns_journey_test.rb). Groups use requirement kind/check type; exact definitions, thresholds and nearby uncertainty stay inspectable. Not root-cause inference or a universal score. |
| E — Human regression admission and corrected-target proof on the same fixed case | [evaluation_test](../test/models/evaluation_test.rb), [support_lab_acceptance_test](../test/services/support_lab_acceptance_test.rb). The source → expert → compiler → calibrated check → failure → future-version regression loop passes with authored records and stubbed targets. |

## E — Continuous evaluation (all P1)

| Check | Evidence and limit |
|---|---|
| E — Production traces/reported corrections → new reviewed scenario → recorded regression | [support_trace_test](../test/services/support_trace_test.rb), [production_trace_journey_test](../test/system/production_trace_journey_test.rb), [recorded_replay_journey_test](../test/system/recorded_replay_journey_test.rb). Uploaded reports are not labels or expectations. |
| E — Existing-scenario retrieval, explicit associations and evidence revision | [trace_scenario_matching_test](../test/services/trace_scenario_matching_test.rb), [failure_matching_journey_test](../test/system/failure_matching_journey_test.rb). Literal hints remain local. [MODEL_FAILURE_MATCHING](./MODEL_FAILURE_MATCHING.md) adds one separately approved fixed-set model comparison, exact quotes and every candidate accounted for; it writes no expert association. |
| E — Automatic proposed failure discovery, emerging families/gaps and expert-only empty draft handoff | [TRACE_FAILURE_DISCOVERY](./TRACE_FAILURE_DISCOVERY.md), [trace_failure_discovery_test](../test/models/trace_failure_discovery_test.rb), [trace_failure_discovery_journey_test](../test/system/trace_failure_discovery_journey_test.rb). Complete traces can have no uploader report; every trace is accounted for. Gaps concern only the disclosed set, not exhaustive company coverage. |
| E — Policy/KB exact dependencies, stale document evidence and fixed history | [source_impact_test](../test/models/source_impact_test.rb), [impact_comparison_journey_test](../test/system/impact_comparison_journey_test.rb). New versions replace evidence explicitly; prior cases/runs never change. |
| E — Product/source changes against explicit unlinked assumptions | [ASSUMPTION_IMPACT](./ASSUMPTION_IMPACT.md), [assumption_impact_test](../test/models/assumption_impact_test.rb), [assumption_impact_journey_test](../test/system/assumption_impact_journey_test.rb). Two complete same-source snapshots plus selected current versions; exact body/endpoint consent, legacy-v1 refusal, no automatic stale flag/revision. |
| E — Richer mutations, calibration analytics and cross-version comparison | Coupled variants in B; calibration in C; [evaluation_run_comparison_test](../test/models/evaluation_run_comparison_test.rb). Compare only identical fixed case/input. Changed definitions stay unmatched and errors unresolved. |
| G — Live usefulness/semantic failure, retrieval and change-impact quality | Stubbed responses exercise contracts, not useful real diagnosis, minimal expert effort, semantic equivalence or company-wide impact recall. No approved live gateway/data exists. |

## F — Classifier factory / P2, explicitly gated

No training/distillation, local small model, fine-tuning, classifier deployment,
automated active learning, advanced benchmark analysis or many vendor adapters ran.
The owner explicitly gates these on enough permitted labels and measured judge
economics. **G** applies to those prerequisites. Machinery is not implemented and
is not counted as delivered; premature training is not a valid completion shortcut.
A later scoped decision must compare held-out human accuracy and cost before use.

## Security, privacy and operations

| Check | Evidence and limit |
|---|---|
| E — Auth/verification/reset/OIDC/break-glass, role/tenant gates and last-Owner protection | Controller/access tests plus [membership_test](../test/models/membership_test.rb) and [security_baseline_test](../test/integration/security_baseline_test.rb). Composite SQL lineage is not RLS; administrators can bypass triggers. |
| E — Fixed artifacts/audits, masking, retention, purge and exports | [audit_event_test](../test/models/audit_event_test.rb), [source_export_test](../test/integration/source_export_test.rb), domain SQL tests. Literal masks are not complete PII detection; purge clears private dependent copies but cannot recall downloads/backups/remote disclosures. |
| E — Six distinct disclosure purposes, exact human consent and revocation | Evaluation/judge, scenario, corpus, matching, impact and trace discovery do not grant one another. All registries default empty. New queued and in-flight revocation tests keep every other purpose approved. |
| E — Real request/DEBUG SQL private-field filtering without changing retained values | [private_logging_test](../test/integration/private_logging_test.rb), [matching access](../test/integration/model_failure_matching_access_test.rb), [impact access](../test/integration/assumption_impact_access_test.rb) and [trace model/job logging](../test/models/trace_failure_discovery_test.rb). Includes requirements, follow-ups, mutation, definitions and new input/result/review fields. Not a proxy/database/browser-history sanitization claim. |
| E — HTTPS/TLS/DNS pinning, special-use refusal, no proxy/redirect/retry and bounded transport | [http_target_transport_test](../test/services/http_target_transport_test.rb), delivery/access tests. In-flight remote copies cannot be recalled. |
| E — Four-database owner/ACL/sequence recovery and real checkpoint upgrade/backup rollback | [OPERATIONS_ACCEPTANCE](./OPERATIONS_ACCEPTANCE.md), `bin/prove-backup-restore`, `bin/prove-upgrade`. Includes all 12 new receipt tables, current/old-code runtime controls, no resend, expiry/purge and precise old-row projections. No PITR, encryption/retention or storage-volume certification. |
| E — Combined tracked-image native jobs and namespace network proof | `bin/prove-compose-runtime` passed/CLEAN in 434.17 seconds before cleanup on the joined head. Kernel IPv4/IPv6 deny, hook-priority refusal, simulated TLS/control/loopback and restart passed; separate native jobs refused matching/impact/discovery without results before/after restart. No public-host certification. |
| G — Clean public host, useful public egress/ingress, public TLS/proxy, SMTP/OIDC and customer live recovery | No authorized host/provider was supplied. Private namespaces and public-shaped TLS peers do not prove public paths. Compose does not enforce safe policy startup order automatically; operators must enforce/verify it before workloads start. |

## UX, frontend, docs and marketing

| Check | Evidence and limit |
|---|---|
| E — QA-lab language, local assets, server-rendered themes, responsive/keyboards and honest states | [lab_shell_test](../test/system/lab_shell_test.rb) and full workflow journeys cover 1280/390/320px, skip/focus/labels, consent/repair, viewer denial, queued/unknown/error, blocked/reviewed/results, CSP and overflow. Browser emulation is not real-device acceptance. |
| E — New non-default states rendered and inspected | STATUS records per-slice captured/inspected desktop/mobile states, including complete-text, source review/coupled variants, all v2 anchors, cross-grader uncertainty, matching consent, exact impact wire and trace gaps. Combined system checks pass 69 tests / 3454 assertions with no failures/errors/skips. |
| E — Support-specific landing/marketing rather than rebuild placeholder | [LANDING](./LANDING.md), [landing_test](../test/system/landing_test.rb). Concrete corpus → expert → calibrated checks → failure → regression copy and real actions; no fabricated customers, pricing, coverage or accuracy. Desktop/mobile/light/dark captures were inspected. |
| E — Lean entrypoints and joined domain/setup/security/hosting guides | Current authorities and feature guides now describe actual fixed contracts, separate purpose scopes, schema/nav/privacy integration and limits. Earlier worker counts remain attributed, not promoted to combined CI. |

## Original prompt crosswalk

Sections 0–3 map to A and the technical-Support thesis; 4 to B; 5–7 to C and
conditional F; 8–10 to D/E and the neutral interface; 11–13 to A/security;
14's eleven steps to B/C/D; every P0/P1/P2 item in 15 to B–F; 16–20 to the
support-distinction, explainable-selection, UX/privacy limits above; 21–23 to A–F,
authorities and stacked delivery. Sections 24–25 remain the final unseen-company
acceptance, not a synthetic-count claim. Nothing restores the old helpdesk.

## Executed evidence and remaining acceptance

Joined focused checks and inspected UI evidence for slices 72–79 live in STATUS.
Slice 80's recovery and upgrade commands pass/CLEAN on the combined schema,
with 12 mixed Rails/ops tests / 107 assertions, Ruby style 371 files, eager loading,
Brakeman zero errors/warnings and gem/importmap audits. The tracked-image Compose
proof passed/CLEAN in 434.17 seconds before cleanup. Full `bin/ci` returned 630
Rails tests / 10133 assertions, two stale prefix-excerpt failures, zero errors/skips;
then 69 system tests / 3454 assertions with no failures/errors/skips. The joined
source-review contract intentionally chooses cue-rich late evidence. Corrected
scale tests assert exact late quotes, historical identity, empty known facts and
empty expert expectations. Their native focused run, including draft quality and
both actual 100,000-input proofs, passed 13 tests / 818 assertions with no
failures/errors/skips at seed 64405. V3 focused checks pass 48 tests / 1083
assertions; v2/v3 browser checks pass 4 / 193, including inspected desktop/mobile
preview, originals, relationships, empty/stopped and repair states. Recovery and
upgrade pass/CLEAN again with exact v3 history, runtime SQL guards, no resend and
purge. Ruby style passes 375 files, eager loading and native audits pass.

Fresh final command:

```sh
DATABASE_URL=postgresql:///navishai_lab_ci81_test CHROME_ARGS=--no-sandbox \
  BUNDLE_FROZEN=true bin/ci
```

Passed in 17m48.72s on the
[implementation head](https://github.com/glnarayanan/navishai/commit/1563e52).
Rails: 640 tests / 10520 assertions, seed 31409, two native processes.
Browser: 71 tests / 3561 assertions, seed 52776. No failures, errors or skips.
Ruby style 375 files, eager loading, gem/importmap audits and Brakeman pass with
zero errors/warnings. Final documentation-only delivery updates do not change
that implementation. Remote PR CI is not this local run.
Ponytail Audit/CE Code Review tools were unavailable; direct risk review and native
checks were used. No static warning exclusions were added.

Remaining: the owner must supply permitted unseen B2B SaaS data,
named expert expectations/held-out labels, exact endpoint approval,
disclosure/retention terms and spend limits for the whole live demo. Measure useful
taxonomy, representative/risky case coverage, correction effort, judge accuracy
and next-agent regressions there. Public-host acceptance needs separate authority.
Classifier/P2 remains gated. Do not call this map “100% product acceptance.”
