# NavishAI next-phase roadmap

**Status:** Approved product and implementation authority

**Decision date:** 27 August 2026

**Completion target:** Build-complete and pilot-ready

This roadmap governs the product phase after the v1 source described in [BUILD.md](./BUILD.md) and evidenced in [RELEASE_CANDIDATE.md](./RELEASE_CANDIDATE.md). `BUILD.md` remains the v1 decision record. When this roadmap adds a requirement, it extends the existing product; it does not reopen the settled architecture, human-authority model, or v1 boundaries.

The owner decides whether one tool implements this roadmap end to end or assigns selected parts to different tools. The milestones and requirement numbers below describe product dependencies and acceptance evidence. They are not tool assignments, prescribed work packages, PR counts, or a schedule.

## 1. Outcome

NavishAI should own the accountable resolution record and connect Support work to Customer Success outcomes. The next phase makes each material recommendation, draft, decision, intervention, and recovery action understandable from durable evidence without turning NavishAI into another broad inbox, chatbot, or workflow platform.

The phase is build-complete and pilot-ready when a reviewer can:

- Take a Support case from investigation through a proofed AI draft, see which material claims are supported, stale, conflicting, uncertain, or refused, and retain human control of the final message.
- Open **Explain this outcome** from a case, Account, run, or health assessment and reconstruct the relevant tasks, evidence, memory, policy, review, edits, runtime choice, usage, failures, and human action without exposing hidden reasoning or secrets.
- See observed usage and budget consumption by run, case, and Account, with money shown only when a trustworthy rate exists and unknown cost never presented as zero.
- Use a source-backed Account dossier that preserves provenance, time, corrections, conflicts, unresolved questions, prior outcomes, and the next human-owned action. Generated summaries remain disposable views.
- Connect recurring Support evidence and human-approved Customer Success interventions to deterministic Account-health changes and renewal windows without claiming causation.
- Diagnose connector, execution, send, indexing, archive, backup, and recovery state from one role-gated operator surface and invoke only safe, auditable recovery actions.
- Run a read-only historical backfill through the existing two-way conversation integration with a dry-run manifest, bounded resumable progress, exception review, and a preservation report.
- Prove a workspace archive round trip, attachment integrity, and memory-index reconstruction from authoritative PostgreSQL records.
- Preview a bounded policy change against retained records, understand the differences and budget effect, canary it on an explicit scope, and roll it back.
- Complete the primary journeys at desktop and mobile widths with keyboard access and clear loading, empty, partial, stale, degraded, blocked, review, error, and success states.

Call this state **build-complete and pilot-ready**. It is not a public release, deployment verification, certification, causal proof, or market validation.

## 2. Product rules

These rules apply to every milestone:

- PostgreSQL remains authoritative. New views and projections must point back to existing durable records instead of creating a second customer, evidence, policy, or execution truth.
- Self-hosted memory remains an index and retrieval engine. A generated summary or external index is never authoritative.
- Rails owns business policy and durable state. The Go runner owns model and tool execution. Rails never invokes a runtime or arbitrary process directly.
- AI output must cite, qualify, or refuse material claims. A human may replace AI text and remains accountable for the exact message they deliberately send.
- No agent, policy, canary, retry, or background job may send, schedule, or trigger a customer message.
- Every tenant-owned read, write, search, export, recovery action, and aggregate fails closed across Workspace boundaries.
- Unknown external effects stop for human review. Retry is allowed only for a definite failure and must be idempotent.
- Current authoritative evidence outranks inference. An authorised human correction has the highest authority. Conflicting history is preserved through correction or supersession, not overwritten silently.
- Self-hosted installations emit no outbound telemetry by default. Product evidence stays local unless an operator explicitly uses an approved integration.
- Use Rails, Hotwire, PostgreSQL, the Go standard library, and current dependencies first. A new production dependency or service requires owner approval.
- Extend the current design language and product surfaces. Do not introduce a new frontend architecture, generic AI dashboard, or parallel component system.

## 3. Existing foundation to extend

Implementation starts by inspecting and reusing these current seams:

| Need | Existing authority or seam |
|---|---|
| Typed crew output and citations | `CrewArtifactPublisher`, `CrewArtifact`, and validated evidence locators |
| Runs, runtime choice, usage, failure, retry | `ExecutionRun`, `ExecutionEvent`, `ExecutionLedger`, and `ExecutionRecovery` |
| Human communication authority | Existing email and conversation draft workflows, frozen deliveries, and unknown-outcome review |
| Customer identity and history | Accounts, Contacts, source identities, conversations, cases, messages, notes, and attachments |
| Durable memory and corrections | `MemoryRecord`, proposals, corrections, supersession, retention, and index reconstruction |
| Account health | Typed Account inputs, deterministic assessments and signals, risk investigations, scorecard versions, and backtests |
| Integration recovery | Signed webhook deliveries, reconciliation cursors, sync operations, and outbound-delivery ledgers |
| Data ownership | Complete Workspace export/import, attachment digests, backup/restore procedures, and audit events |

Do not create a new event bus, rules language, analytics warehouse, customer graph service, billing engine, or observability stack for this phase.

## 4. Scope and non-goals

### Included

- Versioned, typed resolution contracts for the existing Support and Customer Success crew paths.
- Deterministic grounding evaluation and strict AI cite-or-refuse behaviour.
- Human-edit attribution and a unified Explain this outcome view.
- Honest usage, budget, and optional cost rollups.
- A conflict-aware Account dossier over authoritative records and governed memory.
- Append-only, typed business-evidence intake through the current CSV and API boundary.
- Human-owned Customer Success interventions and observed outcome reviews.
- A reliability and recovery cockpit built over current ledgers and minimal additional check records.
- Verified Workspace archive round trips and one historical backfill path through the existing integration.
- Preview, explicit-scope canary, version history, and rollback for bounded policies.

### Excluded

- Autonomous, scheduled, bulk, confidence-threshold, or standing-permission customer sends.
- A customer chat widget, public help centre, social channels, campaigns, or a general omnichannel suite.
- Bot-deflection optimization, autonomous ticket closure, or AI resolution-rate claims.
- A general workflow builder, policy language, agent marketplace, or visual automation canvas.
- A new named helpdesk, CRM, billing, or product-analytics adapter before pilot evidence establishes the source.
- A generic customer-data platform or AI-authored customer summary as a source of truth.
- A billing, invoicing, subscription, or chargeback system.
- A new monitoring platform, log warehouse, or outbound telemetry service.
- Live-model re-execution of historical cases as the default policy-comparison mechanism.
- New communication channels, authenticated browser control, or broader runner egress.
- Public launch, certification, legal review, release signing, managed hosting, or market claims.

## 5. Roles and authority

- Members may inspect proof, explanation, dossier, and cost information for cases and Accounts they are authorised to access. They may propose or complete work allowed by their existing role.
- Managers may review conflicts, approve or abandon interventions, run bounded recovery actions, inspect Workspace rollups, and resolve ambiguous imported records.
- Owners and Admins publish resolution and operational policy versions, configure optional rate information, start a backfill, select a canary scope, roll back policy, and perform protected data operations.
- Existing stricter authority wins. This roadmap does not weaken current send, security, retention, scorecard, integration, or Workspace-deletion permissions.
- Every consequential action records the Workspace, actor, source, time, subject, prior version where relevant, and a bounded non-secret reason or result code.

## 6. Milestone order and status

Implement the milestones in order unless the owner explicitly selects a narrower scope. A later milestone may begin only when its stated dependency is complete and green. Independent research, fixtures, or UI exploration may proceed earlier, but must not create a second implementation path.

| Milestone | Outcome | Depends on | Status | Completion evidence |
|---|---|---|---|---|
| M0 | Rebaselined release candidate | Current main | Complete | `933136dd`; fresh-cache and exact-SHA `bin/ci` green: 547 Rails tests, 45 browser tests, Go checks/builds, audits, contract, seeds, and SBOM. Host omissions are recorded in `RELEASE_CANDIDATE.md`. |
| M1 | Proofed resolutions and explainability | M0 | Complete | M1.1-M1.2 on `phase/m1-resolution-contracts` at `a1a37d5ce41baae5208178fb4855c4957128822c`: 576 Rails tests with 3,559 assertions, 46 system tests with 679 assertions, 100 focused tests with 824 assertions, and 13 repair Ruby files linted. Three forward migrations round-tripped; the tracked structure loaded cleanly and both changed functions matched the migrated database. M1.3 on `phase/m1-human-draft-authority` at `4df61698e1b71e054e10d628e3c05f430c7a5717`: 587 Rails tests with 3,725 assertions, 48 system tests with 725 assertions, 70 focused provenance, controller, send, portability, and retention tests with 700 assertions, and 25 touched Ruby files linted. Its migration round-tripped to the same structure digest, a clean structure load proved all 24 provenance columns, 12 checks, 12 foreign keys, and both delivery guards, and desktop/mobile email and Intercom checks proved generated, human-edited, blocked/refused, and human-authored states with no overflow or keyboard-focus loss. M1.4-M1.5 on `phase/m1-explain-usage` at repair `a9e4b7aa7841ff8fa906dec30e15aa11f960ef31`, with usage commit `2d9a82010c2cc895369e2e87b39f3e4a6b6f1b03` and explanation commit `d419cd3356bb66f294518db8b9f54821c24c0e99`: 615 Rails tests with 4,084 assertions, 50 system tests with 770 assertions, 51 focused protocol, explanation, usage, rate, portability, and read-path tests with 568 assertions, 55 send and deletion regressions with 493 assertions, six repair Ruby files and all 455 Ruby files linted. The migration round-tripped to the same `06eb4f8b` structure digest; a clean SQL structure load proved three tables, two rate columns, eight triggers, five functions, 15 constraints, and the migration row. Protocol and model checks accept the PostgreSQL bigint maximum and reject the next value; adapter and configured totals beyond it preserve terminal ledgers and freeze unavailable nil-money snapshots with observed units and exact provenance. Configured run and search costs survived an exact tenant-safe archive round trip, while the 5,000-run case and Account reads kept exact full-ledger totals and bounded detail. Desktop, 320-pixel mobile, and keyboard checks covered empty, stale, blocked, degraded, error, review, success, Admin rate, and forbidden states without overflow or focus loss; fresh Impeccable layout and type scans found no defects. |
| M2 | Durable customer dossier | M1 | Complete | Source-backed Account dossier and concise case context at `a3c95d7894cb1615e235dfbd23fbd00ee6182ae4`, with Workspace-memory portability repair `fddbdfabe5b06bc244ba0f78f0b94fb41170d621`: 623 Rails tests with 4,165 assertions, 53 system tests with 804 assertions, 80 focused dossier, identity, memory, health, portability, retention, deletion, controller, and read-path tests with 667 assertions, and all 459 Ruby files linted. The bounded dossier read proved 40 identity, 60 fact, and 60 memory detail caps, Account and case query caps of 70 and 75, and both responses under five seconds. Three focused browser tests with 34 assertions covered the full and concise views, conflicts, stale and deleted memory, role-gated identity review, Viewer denial, empty and partial data, long content, keyboard focus, desktop, 320-pixel mobile, no horizontal overflow, and a 48-pixel mobile action. Fresh Impeccable layout and type scans found no defects. An exact archive round trip preserved imported facts and memory correction lineage, removed engine-private index state, rebuilt pending index entries, and kept cross-Workspace data out. |
| M3 | Support-to-renewal outcome loop | M2 | Complete | M3.1-M3.2 typed business evidence and deterministic Support health signals at `63a37ecd5048825a031351f056939c84ca8f37b9`: 628 Rails tests with 4,222 assertions, 54 system tests with 820 assertions, 58 focused health, scorecard, portability, retention, deletion, controller, dossier, read-path, and browser tests with 605 assertions, and all 463 Ruby files linted. CSV and API input retain source namespace and record ID, computed digest, observed and optional valid time, and explicit correction lineage without changing the four-field allowlist or existing size, row, type, role, identity, and Workspace bounds. New 90-day signals count audited human-applied repeated tags, retained reopens, complete resolution-contract results, and resolutions without such proof; existing case, SLA, note, conversation, renewal, use, and contract signals now freeze up to 100 typed source references with exact omitted counts. The new score rules stay off until a human proposes and previews a version and an Admin publishes it. A 101-case read preserved the exact total with 100 references, one omitted reference, no more than 20 queries, and a response under five seconds. The migration round-tripped to the same normalized `7ade75e1` structure digest, and a clean structure load proved five input columns, two signal columns, five named constraints, and the migration row. The archive round trip remapped correction and embedded evidence links. Desktop and 320-pixel mobile browser checks proved record drill-down, keyboard disclosure, no horizontal overflow, readable long citations, and 48-pixel source actions; fresh Impeccable layout and type scans found no defects. M3.3 human-owned interventions and observed outcome reviews at `b0afb86ffdc6f1212ac7eba3e32a7c52ad97c849`: 641 Rails tests with 4,382 assertions, 55 system tests with 849 assertions, 54 focused workflow, controller, portability, retention, deletion, read-path, Account, and dossier tests with 621 assertions, one focused browser test with 29 assertions, and all 472 Ruby files linted. Separate durable records preserve the proposed, approved, completed, abandoned, and reviewed states, exact actor and evidence lineage, and frozen before-and-after deterministic facts. Manager decisions and accountable-human completion never send or schedule customer communication; outcome copy reports association, not cause. A 51-record read kept exact totals, 50 Account cards, 20 dossier records, no more than 85 queries, and a response under five seconds. The archive round trip remapped live and retention-expired evidence and frozen snapshot IDs, and Workspace deletion removed reviewed records. Normalized migration down matched the accepted `7ade75e1` base; repeated development up dumps matched `a97b49a7`; a fresh structure load proved two tables, seven checks, 15 foreign keys, nine indexes, four triggers, four functions, and the migration row. Desktop and 320-pixel mobile checks covered proposal, approval, completion, abandonment, review, empty, overdue, keyboard, focus, 48-pixel actions, and no horizontal overflow. The inspected captures kept AI analysis, deterministic facts, human decisions, and observed outcomes distinct; fresh Impeccable layout and type scans found no defects. |
| M4 | Operational ownership and portability | M3 | Complete | M4.1 reliability and recovery cockpit at `b5f7c6355d042b581c9fedd1fdbed797262ca7ee`: 661 Rails tests with 4,514 assertions, 56 system tests with 870 assertions, 47 focused cockpit, operational-check, recovery, Memory, portability, deletion, and browser tests with 427 assertions, and all 483 Ruby files linted. The Manager-or-higher cockpit derives `healthy`, `attention`, `blocked`, `unknown`, or `not configured` from Workspace-scoped connector, runtime, run, send, Memory, retention, archive, backup, restore, and preflight evidence; shared Solid Queue rows and process heartbeats are excluded because they cannot be tenant-attributed, and missing evidence never yields healthy. It reconciles only a saved ambiguous admission, retries only a definite failure through a deterministic request key, reconstructs Memory through a claimed stable-key path, and links unknown sends to exact-Case investigation without a retry command. Append-only operational checks retain bounded codes, digests, source commits, times, counts, and composite actors without logs or secrets; exact archive remapping and Workspace deletion are green. A 51-record read kept exact totals, 48 detail rows, no more than 90 queries, and a response under five seconds. Normalized migration down matched the accepted `a97b49a7` base; repeated up dumps matched `371b738b`; a fresh structure load proved 17 columns, seven checks, two foreign keys, four indexes, two triggers, one function, and the migration row. Desktop, 320-pixel mobile, keyboard disclosure, confirmation, five-state, Manager, Member-denial, no-overflow, and 48-pixel action checks passed; inspected captures showed no visual defect, and fresh Impeccable layout and type scans found none. M4.2 verified archive round trips at `2679bfab2a61bc9fa425ae67972e2234c9ce0317`: 671 Rails tests with 4,685 assertions, 57 system tests with 880 assertions, 41 focused portability, Memory, controller, and cockpit tests with 495 assertions, 59 portability, deletion, retention, operational-check, and recovery regressions with 647 assertions, and all 483 Ruby files linted. Owner-only Data controls retain a named same-Organisation target only after exact table counts and normalized digests, attachment bytes and SHA-256, critical remaps, actor attribution, tenant links, and durable PostgreSQL Memory reconstruction pass. Target rows, new objects, and the passing operational check form one atomic outcome; every named mismatch and injected upload or success-ledger failure rolls back with bounded append-only evidence. A seeded check completed in 1.683 seconds for 83 tables, 120 records, zero attachments, and two Memory records with evidence digest `329481f5bd080bcff9b4f37bb934a55cead8b29b00821296790dc28ca2132aba`. Desktop, 320-pixel mobile, keyboard focus, confirmation, success, error, no-overflow, and 49-pixel action checks passed; fresh Impeccable layout and type scans found no defects. M4.3 historical Intercom backfill at `c7197afcce08b04232e14b8247eda412601e04be`: 692 Rails tests with 4,842 assertions, 58 system tests with 903 assertions, 63 focused service, controller, Intercom, outbound, and human-send tests with 409 assertions, four focused browser tests with 77 assertions, and all 496 Ruby files linted. A 30-minute digest manifest and repeat GET-only discovery guard all customer writes; bounded batches retain one definite cursor, exact outcomes and reports, recoverable exceptions, current identity review, and audit actors without raw payloads or secrets. Injected pre-boundary failures roll back the conversation, attachment link, stored attachment, blob row, and exact service object; retry imports once with unchanged source bytes and no remote write. Enqueue failure records a durable resumable failure. Portability, retention, deletion, redaction, authorship, timestamps, notes, and attachment acceptance and rejection checks pass. The migration round-tripped to normalized structure digest `8a9706321b158f6a29a1310fc952239ae2f7cf2bba7e5d854e931525eec3ebcd`; a clean structure load proved the migration row, six tables, and 25 matching checks and foreign keys. Desktop and 320-pixel mobile live checks covered completed and stale states, full digests, keyboard focus, zero overflow, and 48-pixel actions; inspected captures showed no visual defect, and fresh Impeccable layout and type scans found none. |
| M5 | Governed policy change | M4 | Complete | Immutable governed proposals, deterministic typed previews, explicit case, Account, or one-profile canaries, frozen future-work selection, and future-only rollback at `e84937ea0df83713284a8cd439de56135f479098`: 715 Rails tests with 5,014 assertions, 60 system tests with 957 assertions, 109 focused service, controller, portability, retention, deletion, concurrency, and policy tests with 1,037 assertions, and all 508 Ruby files linted. Tests deny stale, missing, changed, expired, cross-Workspace, and unauthorised publication; prove preview cannot call the runner, search, integration writes, remote mutation, or customer send; and preserve exact publication, contract, and profile tuples on tasks, events, runs, artifacts, reviews, and rollback history. The archive round trip remaps typed evidence and recomputes truthful digests; retention redacts allowed payloads without breaking immutable identity; Workspace deletion removes governed rows. Normalized migration down/up produced structure digest `15fcfba1344c56d3d02e3e3d17040429aa7d764f70efebe7b3d659215b5aaab9`; a fresh structure load proved four tables, 21 indexes, 10 checks, 35 foreign keys, 12 triggers, 11 functions, and six exact frozen-tuple foreign keys. A 20-subject preview took 72.39 ms and 27 SQL queries versus the same 27 queries for one subject. Desktop and 320-pixel mobile checks cover meaningful and no-change diffs, exact typed facts, stale denial, all three explicit scopes, disclosure, rollback, role denial, keyboard focus, reduced motion, CSP, full content, and safe wrapping; fresh Impeccable layout and type scans found no defects. |
| M6 | Phase-completion proof | M5 | In progress | The repaired source proof currently passes `test/integration/phase_completion_proof_test.rb` with 3 tests and 97 assertions, the elevated repository-native real-Chrome M4/M5/M6 system run with 6 tests and 142 assertions, and the serial full Rails suite with 741 tests and 5,412 assertions. The Support journey now creates blocked and complete artifacts through ordered `ExecutionLedger` terminal events, `CrewArtifactPublisher`, and `ResolutionContractEvaluator`, then performs quality-review request and approval through `CrewWork`; the proof retains separate failed-run lineage, human send, dossier, intervention, reliability, backfill, archive, and policy assertions. Ui.sh was not invoked for this source proof. M6 completion remains contingent on committing this repaired proof and rerunning the remaining repository-native checks. Docker and Podman host checks remain external boundaries. |

Update a status only when work actually starts, becomes materially blocked, or passes its completion evidence. Use `Not started`, `In progress`, `Blocked`, or `Complete`. A merge is not proof of deployment, live integration, pilot use, or validation.

## 7. M0 — Rebaseline the release candidate

### Objective

Establish the current source and release-check baseline before extending the product. Close engineering-controlled regressions and retain a precise boundary around checks that need an external host, credential, legal decision, or signing identity.

### Requirements

1. Run the repository-native `bin/ci` checkpoint from the refreshed main branch and record the exact environment, passing checks, failures, and host-specific omissions.
2. Recheck production container construction, the native Linux runner suite, the supported PostgreSQL and vector-extension upgrade path, backup verification, restore rehearsal, and upgrade preflight wherever the available environment supports them.
3. Fix only confirmed source-controlled defects needed to restore the documented v1 guarantees. Do not pull next-phase product work into baseline cleanup.
4. Preserve legal text, contributor terms, signing identity, deployment-owned TLS and secrets, live credentials, and real pilot use as explicit external boundaries.
5. Update the existing release-candidate record only when current evidence changes. Do not restate it in this roadmap.

### Completion evidence

- `bin/ci` is green, or every omission is proven host-specific and recorded without hiding a source regression.
- No known unresolved engineering-controlled security defect invalidates a next-phase invariant.
- Supported release scripts have focused regression evidence for every path exercised.
- The working tree contains no unrelated owner changes and the baseline result is attributable to an exact commit.

## 8. M1 — Proofed resolutions and explainability

### Objective

Turn the current cited crew artifacts and execution records into an explicit resolution contract that users can trust and inspect.

### M1.1 Typed resolution contracts

- Provide one system-defined contract family for Support resolution and one for Customer Success intervention work.
- Version contracts. Keep one published version per family and Workspace, and freeze the applied version on each evaluated artifact.
- Limit Admin configuration to bounded fields: required claim categories, evidence freshness by supported source kind, mandatory review checks, budget threshold, and whether a missing item blocks readiness.
- Represent at least required facts, material claims, proposed actions, policy checks, uncertainty, and `complete`, `blocked`, or `needs_human` outcome state.
- Do not add arbitrary fields, executable expressions, user-authored code, a general rule graph, or a workflow language.

### M1.2 Claim grounding and cite-or-refuse

- Extend the versioned crew-output schema so material claims are typed and linked to one or more existing validated evidence locators.
- Treat customer or Account facts, product or technical facts, policy or entitlement statements, and promised actions or dates as material.
- Evaluate grounding deterministically in Rails after artifact publication. Validate source availability, Workspace scope, validity or expiry, observed time, freshness policy, and known conflicts from authoritative records.
- A material AI claim must be `supported`, `uncertain`, `conflicted`, or `refused`. Unsupported material text cannot be represented as a supported claim.
- Prevent an AI artifact with a blocking contract result from becoming Draft Ready or receiving an approved quality review. Preserve it as inspectable failed work with exact remediation.
- Keep historical schema versions readable and importable. Never rewrite a prior artifact to satisfy a newer contract.

### M1.3 Human edits and communication authority

- Link an outbound draft to the crew artifact that proposed it and retain the generated-body digest and contract result.
- If a human changes the body, mark the outbound draft as human-edited and record the editor and time. Do not attempt fragile sentence-level authorship inference.
- Show stale, conflicting, refused, or unresolved AI claims during review. A human may add evidence, qualify or remove a claim, or deliberately replace the text.
- A human-authored replacement does not retroactively make the AI artifact grounded. The exact final body and actor remain the communication record.
- Preserve the current fresh authenticated Send command, frozen delivery, idempotency, recipient checks, and unknown-outcome review.

### M1.4 Explain this outcome

- Build one read-only explanation query or presenter over existing authoritative records; do not persist a duplicate explanation narrative as truth.
- Make the view reachable from the relevant case, Account, execution run, and health assessment.
- Show the applied resolution contract, completion state, claims and evidence, source freshness, conflicts, uncertainty, task and run lineage, memory selected, runtime selection and fallback reason, reviews, draft versions, human edits, failures, recovery actions, and the final human send or intervention decision.
- Use progressive disclosure. Lead with the current outcome, blockers, source freshness, responsible actor, and next action; place raw ledger detail behind accessible disclosure controls.
- Never expose hidden reasoning, full prompts, secrets, credentials, broad sensitive logs, or content from another Workspace.

### M1.5 Usage, budget, and cost

- Derive observed input units, output units, search cost units, and budget consumption from current ledgers and aggregate them by run, case, and Account.
- Freeze the provenance and effective version of any conversion rate applied to a run. Permit only an adapter-reported amount or a bounded Admin-configured rate.
- Label calculated money as an estimate, show its currency and rate source, and distinguish partial, unavailable, and not reported states. Never convert an unknown value to zero.
- Keep cost display informational. Do not introduce invoicing, metering for payment, subscription enforcement, or chargeback.

### Completion evidence

- Deterministic scripted runs prove supported, stale, missing, conflicting, uncertain, and refused claims.
- Blocking AI output cannot pass readiness or quality review, while deliberate human replacement remains possible and attributable.
- Existing human-send privilege, freshness, duplicate-send, and unknown-outcome tests remain green.
- Cross-Workspace attempts to inspect contracts, evidence, explanations, usage, or costs fail closed.
- Aggregates reconcile exactly to retained run and search ledgers, including unknown and partial cost cases.
- Browser journeys cover the case proof and explanation flow at desktop and mobile widths, by keyboard, and in loading, empty, stale, blocked, degraded, error, review, and success states.

## 9. M2 — Durable customer dossier

### Objective

Give Support and Customer Success one source-backed view of the customer relationship without promoting a generated summary into authoritative state.

### Requirements

1. Build the Account dossier as a query over current Accounts, Contacts, source identities, conversations, cases, evidence, governed memory, corrections, tasks, health facts, interventions, and outcomes.
2. Organise it around identity, current relationship, verified facts, recent conversations, recurring issues, commitments and decisions, health, unresolved conflicts or questions, and the next human-owned action.
3. Preserve source locator, observed and valid time, freshness, authority, confidence where applicable, correction or supersession lineage, and retention state for every material dossier item.
4. Group competing values without silently choosing an AI-generated winner. Apply the existing authority order and show both the current effective value and retained conflicting history.
5. Reuse existing tasks, case state, and intervention records for next actions. Do not add an unrelated task manager.
6. Generate summaries only on request or as a cached disposable view. A summary must link to the facts it used, disclose its generation time, and remain safe to delete and regenerate.
7. Add a concise Account context section to the case workspace and the full dossier to the existing Account workspace. Do not add a generic customer-data dashboard.
8. Apply existing role, sensitive-memory access, audit, retention, correction, export, and deletion rules to every item and projection.

### Completion evidence

- Fixtures with duplicate identities, superseded memory, human correction, stale sources, conflicting values, deleted content, and unresolved work produce the expected dossier without cross-tenant leakage.
- Every material displayed fact drills into an authoritative record or governed memory item.
- Removing a generated summary does not remove or change dossier facts.
- Query-count and response-time checks prevent the Account and case views from regressing beyond the repository's existing read-path budgets.
- Browser evidence covers full and concise dossier views, conflict resolution entry points, permission denial, empty and partial data, long content, desktop, mobile, and keyboard navigation.

## 10. M3 — Support-to-renewal outcome loop

### Objective

Connect repeated Support evidence and human-owned interventions to deterministic Account health while keeping facts, AI analysis, and observed outcomes distinct.

### M3.1 Typed business evidence

- Extend the current Account CSV and API intake rather than adding a vendor-specific adapter.
- Keep a bounded allowlist of inputs used by current deterministic health or roadmap requirements. Add no open-ended event or property schema.
- Accept source namespace, stable source record ID, observed time, optional validity range, and a digest or locator needed for idempotency and provenance.
- Keep observations append-only. A changed source value uses a new observation or an explicit correction; it never mutates historical input silently.
- Preserve current byte, row, type, role, identity, and Workspace limits. Do not accept executable formulas, arbitrary nested data, or remote URLs through this boundary.

### M3.2 Support evidence in health

- Derive bounded deterministic signals from retained cases, audited case tags, proofed resolution results, SLA history, unresolved commitments, reopened cases, and repeated supported issues. An AI-suggested classification does not become a score fact until a human applies an existing case tag.
- Define each signal's exact window, source query, value, weight, risk points, and citation. Keep AI text out of score calculation.
- Make every material health change drill into the contributing signals, cases, and resolution records.
- Preserve scorecard preview, backtest, Admin publish, versioning, and rollback. New signals remain disabled until a published deterministic scorecard uses them.

### M3.3 Human-owned interventions

- Store interventions separately from crew narratives with the states `proposed`, `approved`, `completed`, `abandoned`, and `reviewed`.
- Link each intervention to its Account, originating health assessment or risk investigation, proposing artifact, supporting evidence, accountable human, expected observable change, target or follow-up date, and bounded reason.
- Require a Manager-or-higher human to approve or abandon an AI proposal. Completing an intervention is a human action and does not send or schedule customer communication.
- At review, freeze the before and after deterministic assessments and relevant typed facts. Record what changed, what did not, uncertainty, and the human reviewer.
- Describe the result as an observed association. Never state that the intervention caused renewal, retention, expansion, or a health change.

### Completion evidence

- API and CSV fixtures prove idempotency, append-only history, correction, ambiguity, limits, invalid types, and cross-Workspace denial.
- Deterministic calculations tie recurring Support evidence to health signals and reproduce the same score from the same versioned inputs.
- An intervention can move through every allowed state, rejects invalid transitions, and retains actor and evidence attribution.
- Outcome review freezes before and after facts and never changes a historical health assessment.
- AI narrative remains visually and structurally separate from deterministic facts and the human decision.
- Browser journeys cover material health change, evidence drill-down, intervention approval, completion, abandonment, follow-up review, empty and overdue states, desktop, mobile, and keyboard use.

## 11. M4 — Operational ownership and portability

### Objective

Make failure, drift, migration, and recovery visible and safely actionable without adding a monitoring platform or weakening external-effect safeguards.

### M4.1 Reliability and recovery cockpit

- Build a role-gated operator view over existing connector, webhook, Workspace-attributable queue evidence, execution, outbound-delivery, memory-index, retention, export/import, and audit state. Shared Solid Queue state without Workspace attribution is not Workspace health evidence.
- Show at least connector readiness and freshness, reconciliation cursor age and drift, failed or replayed inbound deliveries, Workspace-attributable queue lag when available, unconfirmed run admission, retryable and terminal runs, unknown sends, indexing backlog or failure, latest archive verification, latest backup or restore rehearsal, and upgrade-preflight state.
- Add only the minimum append-only operational check record needed for facts not already stored, such as backup verification, restore rehearsal, or upgrade preflight. Store bounded result codes and digests, not secrets or copied logs.
- Calculate status from explicit thresholds and authoritative timestamps. Show `healthy`, `attention`, `blocked`, `unknown`, or `not configured`; absence of evidence is not healthy.
- Offer only bounded actions already safe in the domain: reconcile, retry a definite failure, resume an idempotent operation, reconstruct the memory index, or acknowledge and investigate an unknown effect.
- Require fresh role checks, idempotency, confirmation proportional to impact, and an audit event for each action. Never provide arbitrary command execution or retry an unknown send.

### M4.2 Verified archive round trip

- Add a reproducible operator check that exports a seeded or selected Workspace, imports it into an empty target, verifies table and attachment counts and digests, reconstructs current memory from PostgreSQL, and checks critical relationships and tenant isolation.
- Keep secrets and engine-private identifiers excluded as defined by the current archive contract.
- Record the source commit, archive format, verification time, counts, result, and bounded failure code without retaining archive content in the operational ledger.
- Fail closed on partial import, attachment mismatch, unsupported schema, missing user, cross-Organisation archive, or uncertain index reconstruction.

### M4.3 Historical backfill through the existing integration

- Use the current read-only conversation reconciliation boundary; add no second named importer or generic adapter SDK.
- Start with a dry-run manifest containing available counts, date range, deterministic identity matches, ambiguous records, conversations and parts, notes, attachments, unsupported fields, and expected exceptions.
- Require an Owner or Admin to confirm the manifest before local writes. The backfill must not write, tag, assign, reply, or otherwise mutate the remote system.
- Process bounded idempotent batches with a durable run, cursor, source digest, counts, last definite result, and resumable state.
- Route ambiguous identities through the current review path. Preserve original timestamps, remote identifiers, threading, authorship, source ownership, notes, supported attachments, and deletion or redaction state.
- Pass attachments through current size, type, digest, storage, quarantine, malware-scan, and authorisation controls.
- Stop an uncertain record for review. Never discard, merge, overwrite, or invent unsupported data silently.
- Produce a final preservation report that reconciles discovered, imported, matched, skipped, ambiguous, unsupported, failed, and pending counts and links each exception to a recoverable action.

### Completion evidence

- Failure-injection fixtures cover stale connectors, the shared-queue attribution boundary, replay, runner admission ambiguity, definite retry, unknown send, indexing outage, failed operational check, and recovery idempotency.
- Role and tenant tests prove that diagnostic content and actions cannot cross Workspace or authority boundaries.
- A tested archive round trip preserves authoritative rows, attachment bytes, audit attribution, and memory reconstruction.
- Backfill fixtures prove dry run, approval, resume after interruption, replay, ambiguity, stale remote data, deletion or redaction, attachment rejection, and exact preservation counts.
- No historical-backfill code path can invoke a remote write or human-send service.
- Browser evidence covers cockpit overview and detail, safe recovery confirmation, blocked and unknown states, dry-run review, progress, exceptions, final report, desktop, mobile, and keyboard use.

## 12. M5 — Governed policy change

### Objective

Let operators understand and safely roll out bounded policy changes without a workflow language or nondeterministic historical model reruns.

### Requirements

1. Version only the bounded policies introduced or already governed by the product: resolution contract, quality-review requirement, runtime routing eligibility and fallback, and execution budget. Keep scorecard backtesting in its existing dedicated surface.
2. Freeze policy versions on affected runs, artifacts, reviews, and decisions so history remains reproducible.
3. Preview a proposed version against retained immutable case, Account, artifact, evidence, runtime-capability, and usage records without running a model by default.
4. For each retained subject, show the old and proposed decision, changed blocker or review requirement, routing eligibility or fallback, budget result, and the exact typed facts that produced the difference.
5. State what the preview cannot prove. It does not predict response quality, customer behaviour, resolution rate, or causal outcome.
6. Let an Owner or Admin publish a proposed version to an explicit canary scope consisting of selected current cases, Accounts, or one bounded crew profile. Do not add percentage rollout machinery in this phase.
7. Make the applied canary visible wherever its decision affects work. New work outside the canary continues using the current published version.
8. Support an audited rollback to a prior published version. Rollback affects future decisions only and never rewrites completed records.
9. Deny publication when the preview is missing, stale relative to the proposal, invalid under current security policy, or based on unavailable referenced records.

### Completion evidence

- Deterministic fixtures produce stable old-versus-proposed diffs for grounding, review, routing, fallback, and budget decisions.
- Preview cannot invoke the runner, external search, an integration write, or customer send.
- Only authorised roles can propose, publish, canary, or roll back; concurrent publication and stale previews fail safely.
- Canary selection is explicit, Workspace-scoped, visible in affected work, and absent elsewhere.
- Rollback changes future policy selection while historical records retain their original version and outcome.
- Browser evidence covers proposal, diff explanation, no-change result, stale preview, explicit canary selection, active-canary disclosure, rollback, permission denial, desktop, mobile, and keyboard use.

## 13. M6 — Phase-completion proof

### Objective

Prove that the milestones work together as one secure, understandable operator journey and leave a precise release boundary.

### Required journeys

1. A seeded Support case produces conflicting and stale evidence, a proofed investigation, a blocked AI draft, a corrected or qualified result, a quality review, a human edit, and a deliberate human send.
2. Explain this outcome reconstructs the contract, claims, evidence, memory, runtime, usage, review, edit, send, and failure or recovery lineage for that case.
3. The Account dossier shows the resolved case, retained conflict, correction, recurring issue, current health facts, unresolved question, and next human action.
4. A material deterministic health change opens a risk investigation, produces a cited intervention proposal, receives human approval, is completed, and later receives an observed before-and-after review.
5. The reliability cockpit exposes an injected connector, runner, unknown-send, indexing, and backup-check problem and permits only the corresponding safe recovery path.
6. Historical backfill completes from dry run through preservation report, followed by a verified Workspace archive round trip and memory reconstruction.
7. A policy proposal previews a meaningful difference, runs on an explicit canary scope, remains visible in affected work, and rolls back without rewriting history.

### Required checks

- Run repository-native formatting, linting, dependency audits, static security analysis, Rails tests, Go tests and vetting, runner contract checks, seeded-demo checks, browser tests, and the full `bin/ci` checkpoint.
- Update the threat model for contract bypass, forged claims or citations, stale-source approval, human-edit attribution, cost tampering, dossier leakage, evidence-ingest forgery, intervention authority, unsafe recovery, backfill corruption, policy-preview drift, canary scope escape, and rollback races.
- Run focused adversarial tests for cross-tenant access, privilege escalation, replay, idempotency, stale writes, oversized input, retention and deletion, unknown external effects, and secret or sensitive-data disclosure.
- Inspect meaningful UI at desktop and mobile widths with keyboard navigation, visible focus, semantic structure, safe wrapping, reduced motion, and every required state.
- Re-run archive, restore, reconstruction, upgrade, and supported Linux or container checks wherever the available environment permits. Record unavailable external checks exactly; do not convert them into passing evidence.
- Update current operator, archive, threat-model, and release-candidate documentation only where implemented behaviour or evidence changed.
- Produce one risk-based final review. Apply in-scope evidence-backed findings and record unresolved external boundaries plainly.

### Completion evidence

- Every required journey passes from a fresh supported setup with deterministic fixtures and seeded data.
- All repository-controlled checks are green and no known source-controlled security defect violates this roadmap.
- Meaningful UI evidence exists for desktop, mobile, keyboard, failure, degraded, and recovery paths.
- The milestone status table contains exact commit or PR evidence and checks for M0–M6.
- Remaining gaps require owner authority, credentials, a real deployment, legal review, signing, or market use and are labelled as such.
- The release-candidate record says **build-complete and pilot-ready**, not launched, certified, deployed, or validated.

Optional live integration smoke tests and NavishAI's use for its own human-reviewed support can strengthen owner validation. They do not block build completion and create no public claim by themselves.

## 14. Autonomous execution rules

When the owner assigns all or part of this roadmap:

1. Read `AGENTS.md`, `BUILD.md`, this roadmap, and the current release-candidate record completely.
2. Inspect the current branch, working tree, recent commits, relevant code, tests, and documentation before changing anything. Do not assume this roadmap describes code that has not yet been implemented.
3. State the assigned objective, done evidence, non-goals, dependencies, and constraints before implementation.
4. Reuse the existing authority and service seam named in this roadmap. Prefer a database constraint or deterministic service over prompt-only enforcement.
5. Keep changes cohesive, reversible, and reviewable using atomic Conventional Commits and green PRs as required by `AGENTS.md`. The owner decides the execution grouping and tool assignment.
6. Run focused checks while building and broader native checks at milestone or final handoff boundaries. Visually inspect every meaningful UI change.
7. Update this roadmap's status and evidence only when the implementation state changes. Do not add chat transcripts, research, estimates, or speculative future work.
8. Continue through the assigned scope while safe work remains. Stop only for a material scope, security, data, cost, destructive-action, external-credential, or unapproved-production-dependency blocker.
9. When blocked, continue independent safe work first, then report the exact evidence and smallest owner decision required. Never weaken an invariant to keep moving.
10. At handoff, distinguish implemented, tested, merged, pushed, released, deployed, live-smoked, dogfooded, and validated.

## 15. Decision log

| Date | Decision |
|---|---|
| 27 August 2026 | Keep this roadmap separate from the v1 build record and make it the additive next-phase authority. |
| 27 August 2026 | Target build-complete and pilot-ready; public release and market validation remain separate owner decisions. |
| 27 August 2026 | Build trust, context, Support-to-renewal, operational ownership, portability, and governed policy change without expanding into a broad helpdesk or workflow platform. |
| 27 August 2026 | Keep AI grounding strict while preserving deliberate, attributable human communication authority. |
| 27 August 2026 | Reuse the current integration for one historical backfill path and defer new named adapters until pilot evidence exists. |
| 27 August 2026 | Keep the roadmap tool-neutral; the owner chooses end-to-end or selected implementation and assigns tools after planning. |
