# Original rebuild acceptance checklist

Snapshot: 1 October 2026, exact base
[`a6b3cc0`](https://github.com/glnarayanan/navishai/commit/a6b3cc095a86a1e84a58acb743745559670c7666)
on `origin/rebuild/67-bounded-mined-labels`. **Not `origin/main`: that is the old product.**
This is a requirement map, not a replacement for PRODUCT, ARCHITECTURE, DOMAIN or STATUS.

## Authority, deadline and evidence rules

- Read the owner's **entire original prompt**, message 1, 30 September 19:10:05 UTC,
  in [the source thread](https://ampcode.com/threads/T-01a0f3b9-4f9a-706a-90a2-fcee6f822501).
  Its sections 0–25, A–F and P0–P2 govern this checklist, not agent percentages.
- The latest visible correction is an executor relay, message 3899, 1 October
  20:29:22 UTC: complete original implementation and non-live acceptance within
  eight hours, including security, UX, frontend, docs, marketing and landing;
  only owner live acceptance may remain. Deadline: about **2 October 04:30 UTC /
  10:00 Asia/Calcutta**. The source contains no more detailed marketing brief.
- **[x] E** = implementation and concrete non-live tests exist; not customer proof.
  **[ ] M** = missing engineering or non-live quality/operations evidence.
  **[ ] G** = proof needs customer rights, authoritative experts, approved external
  endpoints/costs, or authority over a host. Mixed rows state both parts.
- Tests below were inspected at this base. Prior runs are attributed separately;
  a test file is not a fresh green run. Synthetic records, mocked gateways,
  reported tools, exact quotes and confidence values do not prove customer quality.
  Example owner counts/coverage percentages are illustrations, not promised thresholds.

## Highest-impact independent work

1. **Privacy:** verify and close unfiltered definition/result fields with real
   request and SQL-bind logging tests. A native filter probe at this base leaves
   `requirements`, `follow_ups`, `input`, `result` and `decisions` unfiltered.
2. **Core value:** improve automatic source-to-scenario extraction and support
   understanding; test diagnostics, contradictory policies, false resolution,
   complexity, entitlements and customer variants independently of the implementation.
   The local draft still copies title/context and extracts action-like sentences.
3. **P1:** implement useful failure discovery, existing-scenario retrieval,
   emerging-family coverage gaps and change-driven maintenance. Uploaded reports,
   literal suggestions and exact linked-document impact are only part of that loop.
4. **Marketing:** replace the rebuild placeholder and stale judge claim with a
   reviewable support-eval landing page, grounded in built capabilities and limits.
5. **Non-live proof:** complete bounded larger full-text/varied workload evidence,
   network allow/deny enforcement and production backup/restore/upgrade rehearsal.
   These are not all customer-data gates.

### Dispatch boundaries after the base

The source thread reports privacy slice 68 in full CI, and assigned matching,
landing, larger-workload and CI workers. Those changes are **not in this base**;
their assignment or focused results do not close acceptance rows here. Avoid
overlapping their files. Additional unassigned units at the ownership check:

| Proposed owner | Files/contracts to own; safe boundary |
|---|---|
| Core scenario quality | `app/services/scenario_mining.rb`, `app/services/scenario_extractor.rb`, focused extraction/mining tests. Improve drafts and independently authored semantic cases; no expert authority. |
| Production failure discovery | New trace-analysis service/job/tests using `support-trace-v1`. Discover candidate failures instead of requiring `observed_failure`; leave matching and its sources controller/view to the assigned worker. |
| Continuous maintenance | New fixed-analysis/source comparison and coverage-gap services/tests; use `Source#dependent_versions` and fixed clusters. Do not edit the workload worker's discovery method or auto-rewrite expectations. |
| Behavioural failure patterns | `EvaluationRunsController#show` and a bounded failure-analysis view/service/tests; current groups use grader-version IDs. Preserve fixed results, uncertainty and human decisions. |
| Operations evidence | `compose.yaml`, `bin/prove-compose-runtime`, `bin/prove-backup-restore`, dedicated ops tests/docs. Prove non-live destination-deny, four-database/ACL restore and upgrade boundaries; public-host authority remains separate. |
| Richer P1 mutations | `Scenario#variant!` and mutation tests/UI. Coordinate with core scenario owner; one-fact copies are the current baseline, not changed-expectation generation. |

## A — Demolition, architecture and delivery

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E Inventory; retain/simplify/transform/delete decisions; architecture review before domain code | [ARCHITECTURE](./ARCHITECTURE.md#inventory-and-disposition), [DOMAIN](./DOMAIN.md), [REBUILD_PLAN](./REBUILD_PLAN.md). Authorities entered in [the reset commit](https://github.com/glnarayanan/navishai/commit/f8200af). Rails/Hotwire/PostgreSQL/native jobs retained; Go/ML workers require a demonstrated need, not automatic reuse. |
| [x] E Remove inbox/tickets/assignment/notes/tags, customer drafts/sends/delivery, SLAs/calendars, account-health/renewals/interventions, crews/personas, broad memory/Supermemory and old explanations | `config/routes.rb`, `db/structure.sql`, `Gemfile`, `compose.yaml`; [lab_baseline_test](../test/integration/lab_baseline_test.rb), especially “old product routes are gone even for an Owner” and “database baseline excludes obsolete tables”. No hidden old-feature compatibility layer. |
| [x] E Re-derive corpus/eval objects and reuse relevant security/provenance, not old schemas or runner ceremony | `app/models/`, `app/jobs/`; [database_preflight_test](../test/services/database_preflight_test.rb), [lab_baseline_test](../test/integration/lab_baseline_test.rb). Fresh lab schema refuses old database names/tables; setup does not reset customer databases. |
| [x] E Boring, private, server-rendered architecture; no universal taxonomy/score, generic tracing platform, prompt manager or premature ML stack | [PRODUCT](./PRODUCT.md), [ARCHITECTURE](./ARCHITECTURE.md), `Gemfile`, `config/importmap.rb`, `compose.yaml`. Three services; Ruby standard HTTP transport; no retained CLI execution, Python, vector/memory service or SPA. |
| [x] E Preserve Git history; small Conventional Commits and stacked PRs with domain tests | Base ancestry and delivered-stack links in [STATUS](./STATUS.md#delivered-stack). Historical helpdesk code stays in Git, not runtime. |
| [ ] M Green final integrated handoff, not just earlier slice counts | `config/ci.rb`, `.github/workflows/ci.yml`; exact-base full CI is not established here. Recorded earlier full checks do not settle later commits or timed-out remote runs. No merge/release/deployment acceptance follows. |

## B — Corpus and scenario foundation (P0)

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E Create an isolated workspace and add practical conversation/document paths | `app/controllers/workspaces_controller.rb`, `app/services/corpus_intake.rb`; [workspaces_controller_test](../test/controllers/workspaces_controller_test.rb), [corpus_intake_test](../test/services/corpus_intake_test.rb), [corpus_journey_test](../test/system/corpus_journey_test.rb). Normalized JSON, narrow Intercom/Zendesk shapes, text/Markdown and explicit JSONL; one or two paths satisfy the first-workflow request. No live connector, PDF or attachment breadth is claimed. |
| [x] E Build normalized corpus, immutable source snapshots and exact provenance; repeat/change semantics | `app/models/{source,source_snapshot,corpus_item}.rb`, `app/services/corpus_intake.rb`; [corpus_intake_test](../test/services/corpus_intake_test.rb), [streamed_corpus_intake_test](../test/services/streamed_corpus_intake_test.rb). Atomic validation, typed context, processing/redaction identity and fixed history. |
| [x] E Explore corpus/source history and context; literal search and pagination | `app/controllers/corpora_controller.rb`, `app/controllers/sources_controller.rb`; [corpus_exploration_test](../test/integration/corpus_exploration_test.rb), [corpus_exploration_journey_test](../test/system/corpus_exploration_journey_test.rb). Escaped retained text and exact source links, not semantic search. |
| [x] E Discover proposed company taxonomy/clusters, review versioned labels, inspect representative/high-risk members and selection reasons | `app/services/corpus_discovery.rb`, `app/services/model_corpus_discovery.rb`, `app/models/taxonomy_version.rb`; [corpus_discovery_test](../test/services/corpus_discovery_test.rb), [model_corpus_discovery_test](../test/services/model_corpus_discovery_test.rb), [family_evidence_journey_test](../test/system/family_evidence_journey_test.rb). Term families/centroids, uploaded boolean reports, keyword risks and proposed document gaps; not verified diagnoses/outcomes. |
| [ ] M Corpus intelligence across recurring/emerging/high-volume/rare-risk issues, repeated escalations/contacts, reopen/false or failed resolution, document gaps/contradictions, agent disagreement, policy exceptions, ambiguity/edge cases, complexity and customer variants | `app/services/corpus_discovery.rb` has terms, literal signals and supplied flags; model instructions mention some distinctions but validation checks schemas/quotes. [corpus_discovery_test](../test/services/corpus_discovery_test.rb) proves critical-minority priority, not these semantic judgments. No complete contradiction, historical-agent disagreement, complexity or policy-exception analysis exists. |
| [x] E Bounded mining, expert nomination and explainable observed selection counts | `app/services/scenario_mining.rb`, `app/models/cluster_member.rb`; [scenario_test](../test/models/scenario_test.rb), [issue_clusters_test](../test/integration/issue_clusters_test.rb). Selected members retain source/reason and represented-family counts; not random sampling or generated-count marketing. |
| [ ] M Demonstrate representative/diverse/business-risk/troubleshooting/escalation/policy-boundary coverage and useful automatic drafts | `app/services/scenario_mining.rb` uses title as situation, context as facts, action-verb sentences and first 4000 characters as evidence. `app/services/scenario_extractor.rb` and model/batch discovery offer structured proposals with exact quotes, not proved entailment or useful extraction. [scenario_extractor_test](../test/services/scenario_extractor_test.rb), [varied_corpus_discovery_test](../test/services/varied_corpus_discovery_test.rb) prove contracts/synthetic partitions only. Improve non-live quality tests now; G applies only to later customer-quality proof. |
| [x] E Review approve/reject/merge/edit/relabel/importance/expectations with immutable source-backed versions | `app/models/scenario.rb`, `app/models/scenario_version.rb`, `app/models/scenario_evidence.rb`; [scenario_test](../test/models/scenario_test.rb), [scenario_access_test](../test/integration/scenario_access_test.rb), [scenario_journey_test](../test/system/scenario_journey_test.rb). Situations, known/hidden facts, permitted knowledge, diagnostic/action/outcome/escalation/grounding requirements; new versions need fresh approval. Account/product state can live in typed facts, not operational account workflows. |
| [x] E Basic controlled scenario families/variants, parent version, exact change, reason and expected difference | `app/models/scenario.rb#variant!`; [scenario_test](../test/models/scenario_test.rb): “variants change one fact retain exact parent and cannot inherit approval”, typed JSON tests. One existing fact changes; expert supplies expected difference and must revise/review expectations. Synthetic variants retain real-source evidence. |
| [ ] M Richer controlled mutations and changed-behaviour assistance (P1) | Current variant API changes one fact and copies parent expectations; no policy/incident/KB/state mutation planner or correct expected-difference generation. More variants alone cannot establish coverage. |
| [x] E Bounded large local processing without silent sampling | `app/models/corpus_analysis.rb`, `app/services/corpus_discovery.rb`; [streaming_corpus_discovery_test](../test/services/streaming_corpus_discovery_test.rb), [streamed_corpus_intake_test](../test/services/streamed_corpus_intake_test.rb), [varied_corpus_discovery_test](../test/services/varied_corpus_discovery_test.rb). JSONL 100,000 records/60 MiB; streaming analysis 100,000/1 GiB with computation budgets. |
| [ ] M Larger complete-text processing and varied operational/quality proof | Streaming v2 still clusters first 4000 characters plus title; full-text v3 covers 2000/10 MiB. [corpus_discovery_test](../test/services/corpus_discovery_test.rb): “explicit full text separates late diagnostic terms without changing the fixed older windows”. Existing 100,000-input synthetic checks prove limits/membership, not arbitrary-corpus throughput or taxonomy quality. |

Text documents can carry macros, SOPs, playbooks, escalation/QA/billing policies,
help-centre/internal/product guidance, incident and Engineering histories; context
can retain CRM/account facts. That is not specialized parsing/understanding of all
those inputs. The owner explicitly deferred connector breadth until one complete loop.

## C — Eval Compiler, graders and human calibration (P0)

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E Suites/cases/contracts freeze reviewed scenarios, exact evidence and grader bindings/versions | `app/services/eval_compiler.rb`, `app/models/{eval_case,eval_case_check,grader_version}.rb`; [eval_compiler_test](../test/models/eval_compiler_test.rb): full hundred-statement coverage, foreign/wrong-version refusal, fresh approval and immutable history. Each outcome/action/forbidden/escalation/grounding statement needs exactly one binding. Useful communication rules can be authored as behaviour, not tone scores. |
| [x] E Deterministic required/forbidden tools, fields, citations, escalation, policy branch, text and order checks | `app/services/deterministic_grader.rb`; [deterministic_grader_test](../test/services/deterministic_grader_test.rb). Checks validate reported structured output; tool names are not attested tool execution and quote presence is not factual correctness. |
| [x] E Versioned rubric/judge execution, fixed model/settings, separate consent, quoted evidence, abstain/error handling | `app/services/judge_grader.rb`, `app/models/calibration_judge_run.rb`; [judge_grader_test](../test/services/judge_grader_test.rb), [judge_execution_test](../test/models/judge_execution_test.rb), [judge_delivery_test](../test/models/judge_delivery_test.rb). A generic approved gateway executes judges; no live vendor/model accuracy proof. |
| [x] E Multi-turn checking and bounded interactive target input | `app/services/{http_conversation_target,deterministic_grader}.rb`; [multi_turn_grader_test](../test/services/multi_turn_grader_test.rb), [http_conversation_target_test](../test/services/http_conversation_target_test.rb). Anchored assistant responses and expert conditional follow-ups, maximum eleven calls, no advance disclosure. Recall/next question/repeated troubleshooting/revised conclusions can be specified, but literal tests do not prove reasoning quality. |
| [x] E Authoritative SME label/correction history, disputes, uncertainty and focused review | `app/models/{human_label,calibration_sample}.rb`, `app/services/calibration_report.rb`; [calibration_test](../test/models/calibration_test.rb), [calibration_review_journey_test](../test/system/calibration_review_journey_test.rb). Personal first-label hiding and latest-per-expert labels; no machine approval or imported correction becomes truth. |
| [x] E Precision/recall, confusion counts, disagreement/inter-rater agreement, thresholds and supplied FP/FN costs | `app/services/calibration_report.rb`, `app/models/calibration_set.rb`; [calibration_test](../test/models/calibration_test.rb), [calibration_cost_test](../test/models/calibration_cost_test.rb), [judge_access_test](../test/integration/judge_access_test.rb). Whole-cohort prediction tallies/exclusions, unknown rates, explicit development/held-out separation; thresholds are endpoint confidence rules, not calibrated probabilities. |
| [x] E Calibration improvement and saved-result labels without rewriting predictions | [calibration_preview_test](../test/services/calibration_preview_test.rb), [result_calibration_test](../test/models/result_calibration_test.rb), [judge_journey_test](../test/system/judge_journey_test.rb). Local revised deterministic development previews and separately requested new judge-version calibration; fresh held-out labels remain necessary. |
| [ ] G Customer expert authority, label sufficiency/representativeness and demonstrated grader accuracy | [support_lab_acceptance_test](../test/services/support_lab_acceptance_test.rb) deliberately includes a fixture judge's missed failure and fixture labels. It does not meet customer calibration acceptance. No arbitrary universal accuracy target was specified. |

## D — Target execution, results and regression (P0)

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E One provider-neutral target contract; scripted proof before HTTP/conversation/replay | `app/models/evaluation_target_version.rb`, `app/services/{scripted_target,http_target,http_conversation_target,recorded_target,support_output}.rb`; [scripted_target_test](../test/services/scripted_target_test.rb), [http_target_test](../test/services/http_target_test.rb), [recorded_target_test](../test/services/recorded_target_test.rb). No ten-vendor build required; replay is fixed output, not a fresh agent response. |
| [x] E Fixed target/cases/inputs, bounded asynchronous execution, once-only claim and unknown-outcome handling | `app/models/evaluation_run.rb`, `app/jobs/evaluation_run_job.rb`; [evaluation_test](../test/models/evaluation_test.rb), [evaluation_delivery_test](../test/models/evaluation_delivery_test.rb), [http_evaluation_test](../test/models/http_evaluation_test.rb). Maximum 50 cases/100 checks; no automatic resend after an unknown external outcome. |
| [x] E Inspect failures, check type/reason, expert importance, exact evidence, judge uncertainty and reported usage/cost | `app/controllers/evaluation_runs_controller.rb`, `app/views/evaluation_results/show.html.erb`; [evaluation_journey_test](../test/system/evaluation_journey_test.rb), [judge_journey_test](../test/system/judge_journey_test.rb). Failure groups use exact grader-version identity; errors/incomplete results are not behavioural failures or passes. |
| [ ] M Rich behavioural failure-pattern analysis | Current grouping is by grader version, not diagnosis/root-cause or new failure-family discovery. Model failure analysis and meaningful cross-grader failure clusters lack implementation/evidence. Expert importance is not measured business severity. |
| [x] E Deliberate human failure admission and future-version regression test | `app/models/evaluation_result.rb#add_regression!`, `app/models/regression_case.rb`; [evaluation_test](../test/models/evaluation_test.rb): “reviewed regressions freeze source failure and corrected target passes the same contract”; [support_lab_acceptance_test](../test/services/support_lab_acceptance_test.rb). Exact failed result/case/reason/human survive later edits. |
| [x] E Connected non-live source → taxonomy → expert scenario → compile → calibrated check → HTTP failure → corrected-target regression | [support_lab_acceptance_test](../test/services/support_lab_acceptance_test.rb), both named tests: “fresh company history reaches calibrated failure and same case regression replay” and “model discovery feeds corrected expert contracts held-out calibration and the same fixed regression”. Authored records, expert judgments and gateway responses; not an unseen customer demo. |

## E — Continuous evaluation (P1)

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E Uploaded production traces, reported corrections, reviewable new scenarios and recorded regression replay | `app/services/{support_trace,recorded_target}.rb`; [support_trace_test](../test/services/support_trace_test.rb), [production_trace_journey_test](../test/system/production_trace_journey_test.rb), [recorded_replay_journey_test](../test/system/recorded_replay_journey_test.rb). Reports are not labels; requirements start empty and experts review them. |
| [x] E Existing-scenario hints, explicit match/different/uncertain history, expert-selected evidence revision | `app/services/trace_scenario_matching.rb`, `app/models/trace_scenario_decision.rb`; [trace_scenario_matching_test](../test/services/trace_scenario_matching_test.rb), [trace_scenario_decision_test](../test/models/trace_scenario_decision_test.rb), [failure_matching_journey_test](../test/system/failure_matching_journey_test.rb). Top-five literal hints, up to 2000 versions/10 MiB; outside-list scoped lookup; no automatic association/approval. |
| [ ] M Automatic failure mining/continuous scenario creation and meaningful existing-case retrieval | [trace_scenario_retrieval_test](../test/services/trace_scenario_retrieval_test.rb) explicitly proves “negated diagnosis ties its opposite and older version wins”, “zero overlap paraphrase misses a causally equivalent situation” and top-five displacement. Uploaded `observed_failure` supplies the current failure signal; the system does not discover it. Non-live engineering can proceed before customer approval. |
| [x] E Policy/KB linked-source impact, stale document evidence, preserved historical cases | `app/models/{source,scenario_version}.rb`; [source_impact_test](../test/models/source_impact_test.rb), [impact_comparison_access_test](../test/integration/impact_comparison_access_test.rb), [impact_comparison_journey_test](../test/system/impact_comparison_journey_test.rb). Exact snapshot/item dependencies, not semantic impact. |
| [ ] M Product-change/stale unlinked assumptions, contradiction/change meaning and emerging-cluster coverage gaps | Current impact follows already-linked evidence; no product-change monitor, cross-analysis novelty/coverage-gap detector or affected-expectation discovery/rerun loop. Source refresh alone cannot establish all affected cases. |
| [x] E Cross-version agent comparisons and richer calibration analytics | `app/models/evaluation_run.rb#compare_with`, `app/services/calibration_report.rb`; [evaluation_run_comparison_test](../test/models/evaluation_run_comparison_test.rb), [calibration_preview_test](../test/services/calibration_preview_test.rb). Exact same case/input only; changed definitions unmatched and missing/error results unresolved. Richer mutation remains M in B. |

## F — Classifier factory and P2 (conditional, not delivered)

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [ ] G Identify stable expensive repeated judgments from enough labelled customer data and judge economics | `app/models/grader_version.rb` supports only deterministic/rubric judges. No classifier dataset/economics proof exists. Labels, permitted use and sufficient held-out truth are real prerequisites; fixture confidence/counts cannot substitute. |
| [ ] M/G Train/distill candidate classifiers; validate held-out human labels; compare judge/classifier quality/cost; version and deploy only where useful | No classifier/training/deployment implementation or tests in `app/`, `lib/`, `test/`. The original Phase F is expressly conditional. Missing machinery is not secretly built, but premature training/deployment would violate the prompt; agree a scoped opt-in once evidence justifies it. |
| [ ] M/G Local small models, fine-tuning, automated active learning, advanced benchmark analytics, many vendor adapters | No dedicated implementation/evidence; these are P2, “only when evidence justifies it”. Current generic adapters, review focus and cohort statistics are not those features. Do not add dependencies or an ML platform to meet a numeric completion claim. |

## Security, privacy, self-hosting and operations

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E Retained auth/verification/reset/OIDC/break-glass, role/tenant isolation and last-Owner protection | `app/controllers/concerns/workspace_authorization.rb`, `app/models/membership.rb`; `test/controllers/{sessions,passwords,verifications,oidc_sessions,break_glass_sessions,workspace_invitations}_controller_test.rb`, [membership_test](../test/models/membership_test.rb), [security_baseline_test](../test/integration/security_baseline_test.rb). Composite relationships and job checks; not PostgreSQL RLS. Raw administrator SQL can bypass last-Owner callbacks. |
| [x] E Immutable artifacts, attribution/audit, explicit schemas and reproducible settings | `db/structure.sql`, `app/models/immutable_record.rb`, `app/models/audit_event.rb`; [audit_event_test](../test/models/audit_event_test.rb), [eval_compiler_test](../test/models/eval_compiler_test.rb), [evaluation_test](../test/models/evaluation_test.rb). Direct SQL mutation/foreign-binding rejection; database administrators can disable triggers. |
| [x] E Configurable masking, provenance/retention/deletion and bounded retained exports | `app/services/{corpus_intake,source_purge}.rb`, `app/jobs/source_retention_job.rb`, `app/models/source.rb`; [corpus_intake_test](../test/services/corpus_intake_test.rb), [source_export_test](../test/integration/source_export_test.rb). Email or explicit case-sensitive literal masks, not complete PII detection. Expiry hides content; purge clears corpus-wide dependants. Export capped at 2000/10 MiB; backups/downloads/remote copies have separate lifetimes. |
| [x] E Minimal explicit purpose-specific provider transmission; hidden expectations/labels stay local; no training | `app/services/{evaluation_http,model_gateway,judge_grader,scenario_extractor,model_corpus_discovery}.rb`; [http_target_test](../test/services/http_target_test.rb), [judge_grader_test](../test/services/judge_grader_test.rb), [model_discovery_test](../test/models/model_discovery_test.rb), [batch_discovery_test](../test/services/batch_corpus_discovery_test.rb). Separate workspace/purpose operator approvals and fresh human consent; source data is untrusted, quote checks do not defeat prompt injection. Gateways must enforce model/settings and data/instruction separation. |
| [x] E Guarded HTTPS/TLS/DNS/IP pinning, no redirects/proxy/retry, bounded transport and revocation/lifetime rechecks | `app/services/evaluation_http.rb`; [http_target_test](../test/services/http_target_test.rb), [http_target_transport_test](../test/services/http_target_transport_test.rb), delivery tests for evaluation/judge/discovery. Local TLS tests exercise real hostname/trust; in-flight disclosure cannot be recalled. |
| [ ] M Complete private-field log protection | `config/initializers/lab_parameter_filter.rb`; native ActiveSupport probe leaves `requirements`, `follow_ups`, `input`, `result`, `decisions` values visible. Existing [scenario_test](../test/models/scenario_test.rb) checks taxonomy-label SQL binds; [corpus_exploration_test](../test/integration/corpus_exploration_test.rb) checks search/content binds. Add actual logging cases for remaining definitions/results, not just filter-name assertions. |
| [x] E CSP, secure headers, escaped untrusted content, host/SSL enforcement and production role separation | [security_baseline_test](../test/integration/security_baseline_test.rb), [production_environment_test](../test/config/production_environment_test.rb), [production_configuration_test](../test/services/production_configuration_test.rb); `compose.yaml`, `db/initialize_runtime_role.sh`, `lib/tasks/production_access.rake`, `bin/prove-container-runtime`. Runtime cannot migrate/disable triggers; no preparation secret in persistent app processes. |
| [x] E Credible self-hosted baseline and disposable local runtime/backup proofs | `Dockerfile`, `compose.yaml`, `bin/prove-{container-runtime,compose-runtime,backup-restore}`, [DEPLOYMENT](./DEPLOYMENT.md). Prior recorded synthetic/native-job, private ingress/TLS/roles, exact primary-schema round-trip and immutable-history checks; not a clean deployment. |
| [ ] M/G Complete useful-egress/private-destination deny proof, production four-database backup/ACL restore, upgrades and clean-host/TLS/proxy acceptance | Current Compose edge network has no explicit destination-deny policy; application checks are not network enforcement. Private namespace tests cannot prove public paths. Primary-schema backup proof omits production queue/cache/cable, owner/ACLs, encryption/retention and PITR. Engineering/rehearsal is M; public host/DNS/mail/identity authority is G. None requires customer records. |
| [ ] G Live SMTP/OIDC, approved target/judge/source-processing gateway behaviour, disclosure/spend and external retention terms | Need exact operator endpoints/credentials and authority; tests use stubs. Live proof is absent, not a reason to postpone local security or engineering checks. No training without separate explicit opt-in. |

## UX, frontend, documentation and marketing

| Check | Evidence at the exact base and remaining acceptance |
|---|---|
| [x] E QA-lab objects/language, local assets, server-rendered pages and themes | `app/views/`, `app/assets/`, [DESIGN](./DESIGN.md), [lab_baseline_test](../test/integration/lab_baseline_test.rb). No inbox/customer-send surface or invented support score. |
| [x] E Desktop/mobile, keyboard/focus/labels, empty/error/blocked/review/queued/success recovery | [lab_shell_test](../test/system/lab_shell_test.rb) covers 1280/390/320px, themes, skip link and denial; scenario/discovery/compiler/calibration/evaluation/judge/conversation/impact browser journeys cover their states, retained repair input, read-only viewers, CSP and overflow. Queued work has explicit refresh; evidence is browser emulation, not real-device or current live UX proof. |
| [ ] M Final integrated rendered acceptance | Prior slice captures are recorded in STATUS; this review did not inspect them or render UI. Verify representative later integrated states, including non-default permissions/errors/unknowns and landing at desktop/mobile. This is pending integration proof, not a claim that existing UI is broken. Impeccable/UI.sh are owner-required quality tools; this doc-only review changed no UI. |
| [x] E Rebuild authorities, lean root and current developer/security/hosting/design docs | [PRODUCT](./PRODUCT.md), [ARCHITECTURE](./ARCHITECTURE.md), [DOMAIN](./DOMAIN.md), [REBUILD_PLAN](./REBUILD_PLAN.md), [DEVELOPMENT](./DEVELOPMENT.md), [SECURITY](./SECURITY.md), [DEPLOYMENT](./DEPLOYMENT.md), [DESIGN](./DESIGN.md), `README.md`, `AGENTS.md`. Old-domain documentation was removed; ownership here is only this checklist. |
| [ ] M Docs reflect final capability/limits and resolve stale statements | `documentation/DEPLOYMENT.md` still says “There is no tracked Compose proof script” before documenting `bin/prove-compose-runtime`; later backup limits still describe Compose ingress as unverified despite the private proof. Separate private from public acceptance and recheck final integration claims. Do not overwrite shared authorities in this task. |
| [ ] M Latest marketing/landing update | `app/views/pages/show.html.erb` is a short rebuild placeholder with “Model judges are next”, contradicted by `app/services/judge_grader.rb` and [judge_execution_test](../test/models/judge_execution_test.rb). Explain technical-Support corpus → scenarios → expert calibration → failures → regression, evidence/private-data limits and a real next action. No fabricated testimonials, coverage, pricing, live accuracy or customer adoption. No dedicated finished-marketing browser proof found. |

## Entire original prompt crosswalk and final acceptance

| Original sections | Checklist coverage |
|---|---|
| 0–3: superseding reset, company-specific thesis/promise, B2B technical SaaS | A; B input note; marketing. No retail, universal labels, helpdesk or copilot substitute. |
| 4: corpus understanding, scenario mining/structure, controlled families | B; core-quality M rows explicitly retain every analysis/selection category. |
| 5–7: compiler, deterministic/judge/classifier separation, mandatory SME calibration | C; conditional F. Communication only where useful, not superficial tone scoring. |
| 8–10: continuous loop, re-derived objects, neutral target interface | E; A/B/C/D. Existing match/new scenario, policy/KB/product/gap maintenance remain visible. |
| 11–13: aggressive removal, selective reuse, architecture decision | A; security/hosting. No required rewrite-for-its-own-sake or obsolete deployment inheritance. |
| 14: eleven-step first complete workflow | Workspace/intake/corpus/analysis/mining/review in B; compiler C; target/run/failures/regression D. |
| 15: every P0, P1, P2 item | B/C/D are all P0; E plus richer mutations covers all P1; F lists every P2 item and its original evidence gate. |
| 16–20: QA-lab UX, quality/coverage not quantity, support-specific focus/intelligence, privacy/trust | B core-quality rows, D failure limits, security/UX/marketing. Required logs/evidence, diagnosis/configuration/defect/dependency, workaround/permanent/partial/false resolution, entitlement/incident/handoff/reopen must not collapse into sentiment or keyword counts. |
| 21–23: A–F, clean engineering, authorities before code, atomic stacked delivery | A–F; docs; final evidence/delivery rules. No compatibility layer, huge-count claims, premature training or universal score. |
| 24–25: previously unseen customer acceptance and north star | Acceptance below; engineering checks are necessary, not sufficient. |

- [x] E Non-live connected loop exists; tests named in D use fresh **authored**
  technical-Support data, fixture expert labels and stubbed model/agent responses.
- [ ] M Finish independent engineering/quality/UX/security/operations/marketing rows
  above. Do not describe their absence as an unavoidable customer-data gate.
- [ ] G Then run the owner's whole unseen-company demo: rights/redaction/retention
  approved → ingest conversations/docs → useful company taxonomy and representative/
  high-risk scenarios → small expert corrections → executable calibrated graders →
  approved support agent → concrete company-evidence failures → next-version regression.
  Customer usefulness, correction effort, semantic coverage and live judge/agent
  behaviour require that evidence. No live/customer acceptance occurred here.
- [ ] G Resolve conditional F/P2 with real label/economics evidence and scoped consent;
  absence is explicit. The eight-hour relay cannot make premature training compliant.

## What this checklist actually verified

Read the original prompt/relay, exact-base code and cited tests, architecture history
and relevant docs. The native `ActiveSupport::ParameterFilter` marker probe confirmed
the unfiltered fields above; it did **not** reproduce all real SQL/request logs.
`bundle check` cannot pass here: locked `json (2.21.2)` is absent. No dependencies
changed; Rails/style/browser/provider/customer checks were not rerun in this orb.
Ponytail Audit/CE Code Review are unavailable; direct source/risk review was used.
Document checks resolve every local Markdown link, confirm A–F/P0–P2 coverage,
check cited named tests against source, and check diff whitespace and one-file scope.

[STATUS](./STATUS.md#expert-conversation-evidence-repair-slice-66) records the latest
preceding full local CI: 473 Rails tests/7246 assertions, 52 browser tests/2416
assertions. Slice 67 records focused 43/886 and five browser journeys/242, not a
full exact-base CI. These are **prior recorded results**, not this review's runs.
STATUS also records a six-hour remote timeout for #187; it is not green evidence.

Delivery: this task changes only `documentation/REBUILD_ACCEPTANCE.md`, commits
locally and supplies `tmp/acceptance-map.bundle` relative to the exact base. The
source thread must integrate it and check its later combined head. No push, merge,
release, deployment, dependency change, customer import or provider call is authorized.
