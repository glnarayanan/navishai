# Architecture decision: support evaluation lab

Accepted for the rebuild, 30 September 2026. Scope: a self-hostable first corpus-to-regression workflow. This decision precedes new domain code.

## Decision

Keep Rails, server-rendered Hotwire, PostgreSQL, and Solid Queue. They already cover authentication, isolation, review forms, transactions, asynchronous work, and authoritative records. Keep Go only where it earns a separate execution/network boundary. Remove the old crew execution domain, subscription CLI framework, broad memory service, and deployment machinery coupled to them.

Do not add Python, a warehouse, vector service, or a frontend dependency tree now. Corpus processing and explicit deterministic baselines can use Ruby/PostgreSQL. A later embedding/clustering or classifier workload may use an isolated Python worker if measured quality or scale needs it. That choice needs pinned inputs, bounded jobs, and a separate dependency review, not a second application backend.

## Inventory and disposition

| Existing subsystem | Decision | Reason |
|---|---|---|
| Local auth, verification/reset, invitations, OIDC, first Owner, break-glass | Retain | Independent and tested security controls. |
| Organisations, workspaces, memberships, last-Owner protection | Simplify | Preserve access checks; remove old-domain associations and callbacks. |
| Headers, CSP, rate limits, sensitive-log filters, audit validation | Retain/simplify | Keep proven controls; replace obsolete audit vocabulary. |
| Rails/Hotwire, local fonts, theme and accessible interaction primitives | Retain | No JS-heavy rewrite; new page composition and product language. |
| Intercom two-way sync, email, attachments tied to messaging | Delete | Operational helpdesk duties. Initial intake uses bounded text/JSON exports. |
| Document extraction and guarded HTTP fetching | Evaluate narrowly | Reuse safe primitives only when the new intake/target interface needs them. No legacy converter just for format breadth. |
| Knowledge versions and source reconciliation | Transform | Rebuild as snapshots/corpus evidence, not case applicability. |
| Cases, identities, SLA, account health, scorecards, interventions | Delete | Abandoned product. |
| Crew tasks/profiles/artifacts, policy publication, execution ledger | Delete | Rails ownership depends on crews. New eval records are smaller and purpose-specific. |
| Broad memory, Supermemory, public agent search | Delete | No memory product or open-ended agent tools in the lab. |
| Go process isolation, provider CLIs/vaults, personal accounts | Delete from first slice | No arbitrary local agent process in the first target interface. Git retains these if a future requirement earns reuse. |
| Solid Queue, cache, cable and Rails runtime | Retain | Native asynchronous jobs and deployment foundation. |
| Old installer, release payloads, Helm/native deployment, archives | Delete/replace | They assume the old topology and cannot certify the rebuilt app. Keep a small current Compose path; do not claim old acceptance. |
| Old fixtures, journeys and obsolete docs | Delete | New tests must prove the new contracts, not preserve removed behaviour. |

## Data and reproducibility

PostgreSQL owns tenant state, sources, snapshots, corpus membership, versioned proposals, human decisions, eval definitions, run state, results, and audit. Use explicit schemas for structured content, database constraints for workspace relationships, and immutable versions for retained definitions. A run freezes case, grader, target, and processing settings before execution. Retrying a job must not duplicate logical records or silently call an external system twice after an unknown outcome.

Use a fresh baseline schema for this unreleased product. Do not drop an existing customer database during normal setup. A database with old helpdesk tables must fail the rebuild preflight; operators preserve or archive it and choose a fresh database. Git history, not a live compatibility layer, preserves old migrations.

## Processing

Intake accepts bounded, valid UTF-8 text/JSON, rejects malformed records atomically, records content digests and redaction, and never renders raw HTML. Large work runs through Solid Queue with progress, limits, terminal errors, and attributable settings. Dataset exploration should paginate; analysis must disclose method and limits. Deterministic term/risk mining is a baseline, not a claim of semantic discovery or 100,000-conversation quality.

Machine proposals never approve themselves. Experts correct taxonomy and scenario expectations before compilation. Calibration binds labels to exact grader/output versions and separates held-out examples. Store individual decisions, not an opaque score.

## External execution

Start with one generic structured target interface and a scripted adapter for contract tests. Rails does not execute model CLIs or shell commands. If Go performs target or judge HTTP calls, use bounded signed requests, explicit endpoint approval, TLS, DNS/IP checks, no redirects, timeouts, bounded output, and no credentials in logs. The domain branches on check/capability types, not vendor names.

Provider disclosure is off unless an authorised human configures and starts it. Do not send hidden expected outcomes to a target. Send only the case's visible context and permitted knowledge. Judge calls may receive the frozen rubric and relevant evidence; source content remains untrusted. Record model/settings, attempts, usage when supplied, and unknown cost honestly.

## Isolation, deletion, and hosting

Every controller and job starts from a checked workspace. Composite relationships prevent foreign evidence and definitions. These checks are not PostgreSQL RLS and must not be described as such. Source retention/deletion must remove content and dependent disclosed copies under explicit policy while preserving a minimal non-content audit. Raw data, redacted snapshots, labels, and outputs have separate lifetimes.

Keep deployment boring: web, jobs, PostgreSQL, and only the execution worker actually needed. No runtime CDN or telemetry. Existing installer/live-host proof does not transfer to this topology. Validate backup/restore, network policy, TLS, and clean-host setup before claiming deployment readiness.

## Alternatives rejected

- Preserve and rename crews: carries persona, helpdesk, and policy state into eval ownership.
- Rewrite the control plane in Python or a SPA: adds two migrations of risk without a demonstrated workload need.
- Retain the full runner for hypothetical targets: keeps a large process/credential surface that the first HTTP target does not need.
- Universal taxonomy and all-LLM grading: loses company judgment and makes simple checks costly and uncertain.
