# NavishAI implementation status

**Status:** Single record of what [PRODUCT.md](./PRODUCT.md) requires, what exists, the evidence, and what remains

**Updated:** 12 September 2026

NavishAI is build-complete and pilot-ready for owner review. That describes the source stack, not a published package, launch, live deployment, certification, product validation, or market result. Update this file when implementation state, evidence, or a dated decision changes; do not reopen the specification here.

## Orb development evidence, 12 September 2026

The committed orb setup installs the pinned Ruby 4.0.6 and Go 1.27.1 toolchains, PostgreSQL 16 with pgvector 0.8.6, system packages, locked application dependencies, and prepared development and test databases. Its warm package check no longer treats the removed `postgresql-contrib-16` virtual package as missing. Two warm setup runs took 4.26 and 4.25 seconds, and the resume hook took 0.06 seconds on this orb.

The declared `web` orb service supervises `bin/dev`, which starts Rails and the local Go runner. It gives the runner a free loopback port, binds Rails to Amp's assigned port, checks `/up`, and publishes the NavishAI portal. `amp orb services ensure --json` reported the service already running, listening, and healthy with HTTP 200. Direct requests to both the portal root and `/up` returned HTTP 200. Development host authorization admits only the exact Amp-provided `PUBLIC_URL` host while `AMP_ORB` is set.

## Installer evidence, September 2026

The guided installer merged in PRs #101 (`fd076df`) and #102 (`eec396b`); dependency pins moved in PR #103. Native fake-Docker coverage proves bundle validation, locks, answer files, consent-gated setup, safe same-release resume, no-token terminal handoff to first-Owner setup, protected system-SMTP, memory-key, and scanner configuration, fixed-path backup/restore helpers, and upgrade success and failure phases. `navishai configure system-mail` replaces only the five system-mail fields from a protected password-file reference and restarts web/jobs; it does not send mail or configure shared-inbox SMTP. Local SMTP tests prove required trusted STARTTLS before authentication and reject a server without STARTTLS before `AUTH`. Disposable Docker evidence covers local-CA first Owner and browser setup, runner ownership, signed callback and artifact flow, pending-memory service suppression, isolated restore of an attachment, memory sentinel, and vault readability metadata, including the managed backup-metadata restore path. A helper-only upgrade retained those records but reused application images, so it proves command, promotion, and retention behavior, not application-image or schema-change compatibility. The restore proof does not validate provider credentials or ClamAV. Changed-image upgrades remain rejected on main by design. Public ACME, release signing, a clean supported-host run of the exact candidate, and a safe pinned-Supermemory first-boot provisioning path remain incomplete. The pinned opaque `server-v0.0.8` binary has no documented noninteractive bearer-key bootstrap or key export interface; current upstream guidance also requires an external provider credential for its TTY first boot. The only evidenced safe path is an isolated human capture followed by protected key entry. The explicit `reveal-owner-token --confirm-reveal` command warns about terminal recording. Production cache, queue, and cable databases use Ruby schemas while primary uses SQL.

On 11 September 2026 the HTTPS candidate acquisition path gained real-transfer proof against a standard-library HTTPS fixture: interrupted transfer then byte-range resume, corrupt-partial removal and fresh download, stale full-size partial rejected by checksum after a 416 reply, restart when a server cannot serve ranges, HTTPS-to-HTTP redirect refusal, HTTPS redirect acceptance, verified-candidate reuse, and a missing-curl stop before any download state. This is integrity against an operator-supplied digest, not publisher authentication. `navishai status` now exits 0 on a valid installation and reports memory, system-mail, and scanner state without secrets.

See [installer acceptance evidence](./INSTALLER_ACCEPTANCE_EVIDENCE.md) for the disposable-host record and its limits, and the guided-installer table below for the I0–I5 reconciliation.

## 1. Capability matrix

Status values: **Built** (implemented, tested, and merged; live-provider or deployed validation is still external), **Done** (implemented, tested, merged), **Partial** (part of the requirement exists; the gap is named), **Deferred** (owner decision to postpone), **Planned** (specified, not started), **External** (needs a host, credential, legal, signing, or market step outside the repository).

### Foundation and security

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Multi-organisation tenancy with isolated Workspaces | Done | `Organization`, `Workspace`, `Membership`, `WorkspaceAuthorization` | Cross-Workspace access fails closed in controllers, jobs, search, memory, integrations, and runner requests. |
| Local auth, verification, reset, invitations, first-Owner bootstrap | Partial | `SessionsController`, `VerificationsController`, `PasswordsController`, `WorkspaceInvitations*`, `FirstOwnerBootstrap` | Bootstrap requires an expiring deployment token and closes after first use. The installer can stage a verified local candidate, ask for consent, and preserve same-release state on resume. Local-CA HTTPS and browser handoff passed; public HTTPS remains unproved. |
| Generic OpenID Connect | Done | `OidcProvider`, `OidcSessionsController` | Code flow with PKCE, state, nonce, exact issuer, allowlisted algorithms; binds only an existing verified User. |
| Protected break-glass administrator | Done | `BreakGlassSessionsController`, `navishai:break_glass:create` | Loopback-only route, deployment token plus password, 15-minute sessions. |
| Owner, Admin, Manager, Member, Viewer roles | Done | `Membership::ROLES` | Role matrix enforced in controllers and services. |
| Append-only audit, secure headers, filtered parameters, rate limits | Done | `AuditEvent`, `Auditing`, `SecurityRateLimits`, CSP initializer | PostgreSQL rejects audit updates and deletes. |
| Application shell, design language, standard states | Done | `app/views/layouts`, `app/assets/stylesheets`, [DESIGN.md](./DESIGN.md) | Desktop, tablet, 390-pixel, and 320-pixel browser coverage; keyboard focus, reduced motion, CSP without inline styles. |
| Threat model tied to implemented controls | Done | [THREAT_MODEL.md](./THREAT_MODEL.md) | Includes contract bypass, forged claims, human-edit attribution, cost tampering, dossier leakage, evidence-ingest forgery, intervention authority, recovery, backfill, policy preview, canary, rollback, provider credentials, hosted search keys, document intake, and host-trusted mode. |

### Guided installer

Reconciliation of [INSTALLER_PLAN.md](./INSTALLER_PLAN.md) slices I0–I5 against merged code and dated evidence. "Native" means fake-Docker or fixture tests in this repository; "disposable" means the orb record in [INSTALLER_ACCEPTANCE_EVIDENCE.md](./INSTALLER_ACCEPTANCE_EVIDENCE.md).

| Slice | Status | Where | Notes |
|---|---|---|---|
| I0 default installation path | Partial | `compose.yaml`, `ops/installer/compose.yaml`, `ops/docker/supermemory.Dockerfile` | Runner boundary, bootstrap-token wiring, and Caddy TLS approach are proven on a disposable host with a local CA. Pinned Supermemory first boot still needs an approved provisioning path; measured host figures are test measurements, not a support minimum. |
| I1 reproducible bundle | Built | `script/candidate_bundle`, `ops/installer/navishai` (`stage_bundle`), `ops/installer/bootstrap` | Canonical payload list, checksum manifest, path-escape and entry-type rejection, HTTPS acquisition with resume and cleanup are native-tested. No signing identity, verification-key distribution, or public endpoint exists. |
| I2 resumable terminal setup and HTTPS | Built | `ops/installer/bootstrap`, `ops/installer/navishai` (`setup`) | Native: consent, answer files, occupied ports, same-release resume, HTTPS-only readiness with no HTTP fallback, publish interruption, image-load failure. Disposable: local-CA install only. Public ACME, real reboot, SSH loss, and a clean supported-host run of the exact candidate remain external. |
| I3 Owner handoff and checklist | Built | `FirstOwnerBootstrap`, `WorkspaceSetupChecklist`, `navishai configure {system-mail,memory,scanner}` | Expiry and once-only claim, terminal-only token reveal, expired-token renewal before any Owner exists, and skipped/configured/tested/blocked states are tested; configured is never shown as tested. An Owner-triggered synthetic scanner check (clean fixture plus EICAR test signature, recorded as an append-only `attachment_scanner` operational check bound to the scanner configuration digest) distinguishes configured, reachable-and-classifying, and blocked; real-malware coverage stays external. Memory stays pending until scoped indexing/retrieval is proven after `configure memory`. |
| I4 day-two commands | Partial | `ops/installer/navishai` (`status`, `doctor`, `backup`, `restore`, `upgrade`) | Fixed-path backup/restore and exact release-identity restore are native and disposable tested. `upgrade` accepts only an identical image set; changed-image promotion is deliberately rejected until compatibility is proven. `doctor` is read-only, lists every finding with a recovery instruction, and offers `--json`. |
| I5 fresh-host acceptance | External | — | Requires a clean supported Ubuntu 24.04 and Debian 12 host, the exact candidate, public DNS/ACME, external ingress isolation checks, and an admin who did not build the installer. Not started; nothing here is inferred from mocked tests. |

### Native helpdesk

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Accounts, Contacts, deterministic identity matching, ambiguity review, reversible merge | Done | `CustomerIdentityGraph`, `SourceIdentityResolver`, `IdentityMatchReview`, `CustomerRecordMerger` | Exact email and domain keys only. |
| Conversations, messages, cases, lifecycle, assignment, tags, notes, priority, resume and reopen | Done | `CaseWorkflow`, `SupportCase`, `SupportCaseStatusChange`, `ConversationThread` | Every transition records actor, source, time, reason, prior state. |
| Inbox and case workspace UX | Done | `SupportCasesController`, `support_cases` views | Queue filters, history, responsive conversation view, next-action rail, concise Account context. |
| SLA engine with calendars, holidays, pause, warnings, escalation | Done | `SlaEngine`, `ServiceCalendar`, `SlaPolicy`, `CaseSla`, `SlaEscalationTask` | Boundary-time deterministic tests. |
| Workspace support quality readout | Built | `SupportQualityReadout`, `SupportQualityController` | Read-only live SLA, reopen, unproofed-resolution, and blocked-draft counts from retained PostgreSQL facts. Members and viewers can read. Does not score Accounts or send messages. On `cursor/support-quality-efe6`. |
| Shared-email intake with signed webhook, threading, duplicate suppression | Done | `SharedEmailIntake`, `Webhooks::SharedEmailController`, `InboundEmailDelivery`, `EmailThread` | 10 MiB source, 1 MiB text, five-minute skew. |
| Human-only email send with attribution, idempotency, unknown-outcome review | Done | `HumanEmailSend`, `HumanSendAuthorization`, `OutboundEmailDelivery`, `EmailRepliesController` | No agent or job entry point; retry cannot duplicate. |
| Attachments with sniffing, limits, quarantine, authorised download | Done | `AttachmentIntake`, `StoredAttachment`, `AttachmentDownloadsController` | PDF, text, PNG, JPEG, GIF by signature; 5 MiB per file, 10 MiB per message. |
| Malware-scan contract and reference adapter | Done | `AttachmentScanner`, `AttachmentScanner::Clamd`, `AttachmentScannerCheck` | ClamAV INSTREAM adapter selected by `NAVISHAI_ATTACHMENT_SCANNER=clamd`; default keeps every file quarantined. Owners test the configured daemon from the setup checklist with a clean fixture and the EICAR signature; the result is an append-only operational check. |
| S3-compatible object storage | Deferred | `config/storage.yml` | Owner deferral on 6 September 2026; only the local disk service is configured and tested. |
| Knowledge: maintained text, URL snapshots, versions, freshness, expiry, full-text search, citations | Done | `KnowledgeIngestion`, `KnowledgeUrlFetcher`, `KnowledgeSearch`, `KnowledgeSource(Version)` | SSRF-safe fetch, immutable versions, stale and deleted warnings. |
| Knowledge improvement queue | Built | `KnowledgeImprovementQueue`, `KnowledgeImprovementsController` | Read-only list of stale, deleted, retired, and failed-sync sources. Members and viewers can read. Does not mutate knowledge or send messages. On `cursor/knowledge-improvements-efe6`. |
| Knowledge document uploads: text, Markdown, HTML, PDF, DOCX, ZIP bundles | Built | `KnowledgeDocumentExtractor`, `KnowledgeZipBundle`, `pdf-reader` | One source per bundled document; bounded pages, bytes, entries; CRC-verified archive reader. |
| Knowledge legacy DOC uploads | Built | `KnowledgeDocumentGateway`, `runner/internal/documents`, `navishai-document` | Clean scan precedes signed, Workspace- and digest-bound LibreOfficeKit conversion; the scanned original stays attached and extracted text is bounded to 1 MiB. |
| Intercom Help Center as a synchronised knowledge source | Built | `IntercomHelpCenterSync`, `KnowledgeSyncPass`, `KnowledgeSyncObservation` | Bounded resumable scans; immutable origin and versions; two complete absence confirmations retire a source. Republish restores visibility and preserves history. |
| Notion knowledge and personal connector accounts | Built | `WorkspaceConnector`, `IntegrationOauth`, `NotionKnowledgeSync` | Admin enablement and encrypted Workspace credentials; separate personal OAuth browsing. Shared Notion roots use complete-pass reconciliation. Personal content is not automatically shared. |
| Product and Intercom applicability | Built | `KnowledgeApplicabilityScope`, `Product`, `KnowledgeApplicability` | Dynamic connection defaults, human overrides, case product assignment, scoped retrieval and citation admission. |
| Web companion with personal AI accounts | Built | `PersonalProviderAccount`, `runner/internal/personalaccounts` | Codex device login and execution on deployed Linux, owner-scoped credential homes, explicit runtime approval, fixed retry identity, revocation and deletion purge. Other personal AI provider adapters are not implemented. |

### Durable agent work and runtimes

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Support and Customer Success crew templates, bounded agent profiles and versions | Done | `CrewConfiguration`, `AgentPolicy`, `AgentProfile(Version)` | Eight fixed roles; Admin-editable within bounds; non-admins cannot expand authority. |
| Durable tasks, handoffs, dependencies, comments, evidence, reviews, cancel, retry | Done | `CrewWork`, `CrewTask`, `CrewTaskEvent`, `CrewTaskDependency`, `CrewEvidenceResolver` | Refresh and retry preserve state. |
| Versioned runner protocol with signed requests, admission, idempotency, health | Done | `RunnerClient`, `RunnerProtocol`, `runner/internal/{protocol,admission}` | HMAC-signed requests, five-minute skew, `POST /v2/runs/admit`, `/livez`, `/readyz`; Rails-to-Go contract check in `script/runner_contract`. |
| Deterministic scripted adapter | Done | `runner/internal/scripted` | Success, retry, timeout, cancellation, malformed output, policy denial. |
| Run ledger, ordered events, replay, attempts, usage, terminal rules | Done | `ExecutionLedger`, `ExecutionRun`, `ExecutionEvent`, database triggers | Duplicate and out-of-order events rejected by PostgreSQL functions. |
| Execution supervision: roots, limits, timeout, cancellation, reaping, credentials, egress | Done on Linux | `runner/internal/supervisor`, `runner/internal/isolation`, `navishai-exec`, `navishai-netns-launch` | Landlock, seccomp, namespaces, resource limits, deny-by-default egress profiles bound to the exact executable. |
| macOS host-trusted execution for Codex and Cursor | Partial | `runner/internal/adapters/cursorhost`, `RuntimeInstallation` execution modes | Works as an explicitly enabled `host_trusted` mode without kernel isolation. The new web companion runs personal Codex accounts on deployed Linux. This retained legacy mode still requires explicit opt-in and remains an operator-accepted risk. |
| Investigation, drafting, quality review, artifacts, change requests, reruns | Done | `CrewArtifactPublisher`, `CrewArtifact`, `CrewWork` review commands | Strict artifact schema with citations, uncertainty, conflicts, versions. |
| Execution UX and recovery | Done | `ExecutionRunsController`, `ExecutionRecovery`, run panel views | Live progress, blocked, degraded, failed, canceled states; reconcile and retry. |
| Runtime approval registry with detection, fingerprints, tests, compatibility | Done | `RuntimeRegistry`, `RuntimeInstallation`, `RuntimeInstallationsController`, `runner/internal/runtimecatalog` | Approval requires a passing test of the exact configuration fingerprint. |
| Codex, Claude, Grok (ACP), Cursor (ACP) subscription adapters | Done | `runner/internal/adapters/{codex,claude,grok,cursor}` | Mocked contracts plus opt-in live smoke tests that consume the operator's subscription. |
| Direct OpenAI and Anthropic API-key connections | Done | `ProviderConnectionGateway`, `ProviderConnectionsController`, `runner/internal/{providerapi,providerconfig}` | Owner-approved extension of interview decision Q12; keys live only in the encrypted runner vault. |
| Routing, fallback, budgets, disclosure, hard stops | Done | `RuntimeRouter`, `UsageCostCapture` | Incompatible fallback denied with a visible reason; adapters stop at unit caps. |
| Public-web search: SearXNG | Done | `runner/internal/websearch`, `PublicWebResearch` | Self-hosted default. |
| Public-web search: hosted providers | Partial | `runner/internal/websearch/hosted.go` | Exa and Tavily implemented with runner-held keys. Parallel is not implemented. Admin per-Workspace provider selection is built; requests freeze the selected provider across retries. Native runtime search remains unavailable under the [checked current protocols](./NATIVE_RUNTIME_SEARCH_PROTOCOL.md). |
| Guarded extraction | Done | `GuardedWebFetcher`, `PublicWebExtractionWorkflow` | DNS and redirect revalidation, private-network denial, 1 MiB, active content stripped. |

### Memory

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Memory contract, four types, scopes, provenance, supersession, retention | Done | `MemoryRecord`, `MemoryScope`, `MemoryGovernance` | |
| Self-hosted Supermemory integration with tenant isolation | Done | `SupermemoryEngine`, `MemoryEngine`, `MemoryIndexer`, `MemoryIndexEntry` | Managed host rejected; stable Memory key is the document identity. |
| Capture, proposals, procedural publication, consolidation | Done | `MemoryCapture`, `MemoryProposal`, `MemoryPublication` | |
| Context assembly, citations, no chain of thought | Done | `MemoryContext`, `ExecutionMemorySelection` | Eight records, 4 KiB each, 16 KiB total, frozen on the run. |
| Inspection, correction, tombstones, sensitive-access audit | Done | `MemoryRecordsController`, `MemoryCorrectionsController`, `MemoryDeletion`, `MemoryTombstone` | |
| Degraded mode, retry, reconstruction, export and import | Done | `MemoryPortability`, [MEMORY_ARCHIVE.md](./MEMORY_ARCHIVE.md) | Supermemory-offline journey tested. |

### Intercom and Customer Success

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Two-way Intercom sync with webhooks and reconciliation | Done | `IntercomSync`, `IntercomOutboundSync`, `IntercomClient`, `Webhooks::IntercomController` | Contacts, companies, conversations, parts, redaction, tags, assignment, notes. |
| Human-only Intercom send | Done | `HumanIntercomSend`, `IntercomRepliesController`, `IntercomOutboundDelivery` | |
| Historical Intercom backfill | Done | `IntercomHistoricalBackfill`, `IntercomBackfill*` models, `IntercomBackfillJob` | GET-only, confirmed manifest, resumable batches, preservation report. |
| Typed Account inputs by CSV and API, append-only, idempotent | Done | `AccountDataImport`, `AccountHealthInput` | Bounded allowlist; corrections by new source ID. |
| Deterministic health signals including Support evidence, material change, renewal windows | Done | `AccountHealth`, `AccountHealthAssessment`, `AccountHealthSignal`, `HealthEvidence` | Score rules stay off until a published scorecard uses them. |
| Scheduled recalculation | Done | `AccountHealthScheduledRecalculationJob`, `config/recurring.yml` | Daily at 01:30 per active Workspace, plus input-change triggers. |
| Risk investigation and crew analysis | Done | `AccountRiskWorkflow`, `AccountRiskInvestigation` | |
| Human-owned interventions with outcome reviews | Done | `CustomerSuccessInterventionWorkflow`, `CustomerSuccessIntervention(OutcomeReview)` | Association, never cause. |
| Conversational scorecard designer with backtest, publish, rollback | Done | `HealthScorecardDesigner`, `HealthScorecardBacktester`, `HealthScorecardPublisher` | |

### Proof, explanation, dossier, policy, and operations

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Typed resolution contracts, versioned per family and Workspace | Done | `ResolutionContractFamily`, `ResolutionContractVersion`, `ResolutionContractConfiguration` | Bounded Admin fields only. |
| Deterministic claim grounding and cite-or-refuse | Done | `ResolutionContractEvaluator`, `CrewArtifact` grounding columns | Blocking results cannot reach Draft Ready or approved review. |
| Human-edit provenance on drafts | Done | `HumanDraftProvenance`, provenance columns on drafts and deliveries | |
| Explain this outcome | Done | `OutcomeExplanation`, `OutcomeExplanationsController` | Reachable from case, Account, run, health assessment. |
| Usage, budget, and cost rollups | Done | `UsageCostSnapshot`, `UsageRateSetting(Version)`, `UsageRatesController` | Unknown cost never shown as zero. |
| Account dossier and concise case context | Done | `AccountDossier` presenter | Bounded caps and query budgets tested. |
| Reliability and recovery cockpit with operational checks | Done | `ReliabilityCockpit`, `ReliabilityRecovery`, `OperationalCheck` | Five explicit states; bounded actions only. |
| Verified Workspace archive round trip | Done | `WorkspacePortability`, `WorkspaceDataControlsController#verify_archive`, [WORKSPACE_ARCHIVE.md](./WORKSPACE_ARCHIVE.md) | Owner-only; atomic target creation plus check record. |
| Governed policy change: preview, canary, publish, rollback | Done | `GovernedPolicyChange`, `GovernedPolicyResolver`, `GovernedPolicy*` models | Explicit scopes only; rollback affects future work only. |
| Integrated end-to-end proof of the seven journeys | Done | `test/integration/phase_completion_proof_test.rb` | Passes from code on a fresh host (section 2). |
| Notifications: in-app, email, signed outbound webhooks | Done | `NotificationFanout`, `NotificationMailer`, `OutboundWebhookFanout`, `OutboundWebhookTransport` | |
| Retention, expiry, tombstones, protected Workspace deletion, full export and import | Done | `WorkspaceContentExpiry`, `WorkspaceDataGovernance`, `WorkspaceDeletion`, `WorkspacePortability` | |
| Docker Compose deployment with isolated runner | Done | `compose.yaml`, `ops/docker`, `ops/compose` | No Docker socket; capabilities dropped. |
| Native Linux deployment | Done | `ops/systemd`, [DEPLOYMENT.md](./DEPLOYMENT.md) | Separate runner user; Landlock helper. |
| Helm chart with Compose parity | Deferred | `ops/helm/navishai` | Experimental; owner deferral on 6 September 2026. |
| Backup, verification, restore, restore test, upgrade preflight, major-version upgrade | Done | `ops/compose/*`, [OPERATIONS.md](./OPERATIONS.md) | Live Compose runs need a Docker host (section 4). |
| SBOM, release manifest, dependency record, patch policy | Done | `script/sbom`, `script/release_manifest`, [DEPENDENCIES.md](./DEPENDENCIES.md), [RELEASE.md](./RELEASE.md) | Signing identity is external. |
| Seeded demonstration Workspace | Done | `db/seeds/demo.rb`, [DEMO.md](./DEMO.md) | |
| Public product page | Done | `PagesController`, `app/views/pages/show.html.erb` | Pricing and testimonial sections intentionally omitted. |
| Check-host preparation for ephemeral environments | Done | `script/prepare_check_host`, `.claude/hooks/session-start.sh` | Builds pinned pgvector and Ruby from source when download hosts are blocked, and installs a checksum-verified ChromeDriver for the bundled Chromium so the browser suite runs in web sessions. |

## 2. Evidence

`bin/ci` is the source checkpoint: Ruby and Go style, gem and Importmap audits, Brakeman, the full Rails and browser suites, Go vet and tests with the process-isolation suite required, the Rails-to-runner contract, seeds, and the SBOM check. Record host omissions rather than treating a partial run as green.

### 12 September 2026 support quality readout (D1)

On `cursor/support-quality-efe6` from verified `main` (`aa4b079`). Every Workspace member, including Viewer, can open a read-only Quality page that counts open cases, open first-response and resolution SLA breaches, latest retained reopen and unproofed-resolution health signals, proofed resolutions, and current contract-blocked drafts. Open case volume alone is not attention. Generating the page does not score Accounts or send messages. Cross-Workspace paths fail closed. Independent of the A/B and C stacks. Focused checks: presenter and controller 8 runs, 72 assertions; one system test, 14 assertions including 320px overflow and a case link. RuboCop clean on touched Ruby files. Isolation and Docker omitted on this host.

See [NEXT_PHASE_EXECUTION.md](./NEXT_PHASE_EXECUTION.md) for A/B PR URLs and remaining C/D/E slices.

### 12 September 2026 knowledge improvement queue (D2)

On `cursor/knowledge-improvements-efe6` from D1. Every Workspace member, including Viewer, can open a read-only Improvements page that lists stale (expired or sync-unavailable), deleted, retired, and failed-sync knowledge sources. Current sources stay off the queue. Cross-Workspace paths fail closed. The Knowledge library links to the queue. Focused checks: presenter, controller, and system 6 runs, 54 assertions, including 320px overflow and a stale-source link. RuboCop clean on touched Ruby files.

### 12 September 2026 knowledge follow-up evidence (D3)

On `cursor/knowledge-follow-up-efe6` from D2. Adding a non-stale current version removes the source from the attention queue and records it under Recently improved with prior/current version numbers. The source page keeps immutable version lineage and states that the source left the queue. Focused checks: presenter, controller, and system 9 runs, 89 assertions. RuboCop clean on touched Ruby files.

### 11 September 2026 stacked follow-up checkpoint

On the top of the seven-branch stack (`claude/great-gauss-vo8e8g` through `claude/great-gauss-vo8e8g-scanner-check`, PRs #104–#110) on the same check host, now with the matching ChromeDriver installed by `script/prepare_check_host`:

| Check | Result |
|---|---|
| Full Rails suite | 1,096 tests, 7,920 assertions, pass |
| Full browser suite | 78 tests, 1,296 assertions, pass; first complete browser run in a web session |
| RuboCop, Brakeman, gem audit, Importmap audit | 621 files, no offences; no warnings; no vulnerabilities |
| `bash -n` on both installer scripts and the check-host script, `git diff --check` | pass |
| Runner isolation suite, runner contract, legacy DOC conversion, Docker paths | Omitted: no Landlock and no Docker daemon on this host; not claimed green |

The stack adds: host check before candidate download, sudo guidance for an unwritable candidate store, stall detection instead of a transfer cap, bounded HTTPS readiness polling, `navishai renew-owner-token`, release identity in `status`, a read-only `doctor` with `--json`, the Caddy image digest, relative renewal dates in tests, ChromeDriver installation for the check host, and the Owner-run synthetic scanner check. None of it is released, deployed, or host-validated.

### 11 September 2026 installer rebaseline

From `24e1ae5ab11b392603559dd57322e1e8d8f2ea1a` plus the fixes on this branch, on a Linux 6.18 x86-64 check host prepared by `script/prepare_check_host`: Ruby 4.0.6, Go 1.27.1, PostgreSQL 16.15 with pgvector 0.8.6, the committed `Gemfile.lock`. This is a native rebaseline of the current dependency set, not a host installation.

| Check | Result |
|---|---|
| Full Rails suite | 1,075 tests, 7,752 assertions, pass on the finished branch. On the unmodified baseline two `AccountHealthTest` cases failed because the import path recalculated at the real clock while fixture renewal dates had passed; freezing the test clock at its fixed instant resolved both without touching application code. |
| Bootstrap, installer, candidate bundle, and clamd adapter tests | 107 tests, 726 assertions, pass, including 8 new HTTPS fixture cases and the status regression |
| System mail, production environment, and checklist controller tests | 9 tests, 51 assertions, pass |
| RuboCop, Brakeman, gem audit, Importmap audit | 615 files, no offences; no warnings; no vulnerabilities |
| Go vet, gofmt, Go tests without the isolation requirement | Pass |
| Shell syntax and whitespace | `bash -n` on both installer scripts and `git diff --check` pass |
| Browser suite | Omitted: the host has ChromeDriver 147 but Chromium 141 and cannot reach the driver download service |
| Runner isolation suite, runner contract, legacy DOC conversion, live Compose paths | Omitted: no Landlock on this kernel and no Docker daemon; not claimed green |

### 9 September 2026 legacy DOC checkpoint

On this Linux 6.1.158 x86-64 orb: Ruby 4.0.6, Go 1.27.0, PostgreSQL 15.19, and LibreOffice 7.4.7.2. The Debian Bookworm packages `libreoffice-core`, `libreoffice-writer`, and build-only `libreofficekit-dev` were all `4:7.4.7-1+deb12u14` from source package `libreoffice`. This host has no PostgreSQL 16 APT package, so setup used its documented `PG_MAJOR=15` override; that is a host deviation, not a production-pin change.

| Check | Result |
|---|---|
| Focused legacy Rails service and gateway tests | 13 tests, 88 assertions, pass |
| Full Rails suite | 961 tests, 6,990 assertions, pass |
| Focused legacy DOC system test | 1 test, 10 assertions, pass; desktop and 320-pixel screenshots inspected |
| Document and mandatory supervisor isolation tests | Pass with `NAVISHAI_REQUIRE_ISOLATION_TESTS=1` |
| Native helper builds and genuine DOC conversion | `navishai-runner`, `navishai-exec`, `navishai-netns-launch`, and `navishai-document` build; `TestInstalledLibreOffice` passes through `navishai-exec` and removes its temporary directory |
| Signed Rails–Go contract | `script/runner_contract` passes its scripted run and genuine legacy DOC conversion |
| Image smoke | Added to the manual workflow: it checks Writer and all three helpers, then converts `test/fixtures/files/knowledge-legacy.doc` in the built image. Omitted locally because this orb has no Docker daemon. |
| Clean `bin/ci` | Pass: all 13 declared steps completed with exit 0 after removing `tmp/navishai-runner`, `tmp/navishai-exec`, `tmp/navishai-netns-launch`, and `tmp/navishai-document`. The runner build now compiles all four binaries before the genuine DOC test. |

### 6 September 2026

Branch `claude/docs-build-contracts-review-nx2rly` from main `5e35f5e3d3d536f0006bdfc0af47474f0dbcf459`, on a fresh Linux 6.18 x86-64 host prepared by `script/prepare_check_host`: Ruby 4.0.6 built from the `ruby_4_0` branch at 4.0.6 patch level 0, Go 1.27.0, PostgreSQL 16.15 with pgvector 0.8.6 from the pinned source revision, Chromium 141 with a matching ChromeDriver.

| Check | Result |
|---|---|
| Integrated proof | 3 tests, 97 assertions |
| Rails suite | 874 tests, 6,546 assertions, no skips |
| Browser suite | 67 tests, 1,159 assertions, no skips |
| RuboCop | 539 files, no offences |
| Brakeman, gem audit, Importmap audit | No findings |
| Go vet, 17 packages, 3 Linux binaries, runner contract | Pass |
| Seeds, SBOM | Pass; 89 locked production components |
| Runner isolation suite | Omitted: no Landlock on that kernel; fails under `bin/ci` by design |
| Live Compose paths | Omitted: no Docker or Podman on that host |

### 10 September 2026 installer I0 investigation

An a1.medium Debian 12 x86-64 orb ran the uncommitted installer-plan and first-Owner snapshot through a real disposable Docker Engine 29.8.0 daemon with Compose v5.5.1. It built the current local Compose images, but did not install a release bundle or run an installer.

- **Host measurement:** 4 CPUs, 7.8 GiB RAM, and 60 GiB free before build; 42 GiB free after. The images totalled 1.262 GiB and build cache 1.732 GiB. This is a test measurement, not a support minimum.
- **Security boundary:** the runner used uid 1000, dropped all capabilities, enabled `no-new-privileges`, had no Docker socket, and joined only the internal control network. Runner data, Rails storage, and the `0600` runner key were accessible to the intended uid.
- **Blocker:** pinned Supermemory Local 0.0.8 needs a provider key or interactive first boot before it becomes ready. Its doctor confirmed encrypted uid-1000 persistent state and local embeddings, but reported no model-provider key. No credential, provider request, or log-based key capture occurred. The full stack therefore cannot prove a no-credential guided install until this prerequisite has an approved safe path.
- **Exposure boundary:** Supermemory shares the edge network and publishes port 3000 while Rails and jobs share its network namespace. This test did not prove intended public ingress only, so the guided HTTPS design remains unresolved.

### 27 August 2026 rebaseline

From `fbf65f0b3c268f650a2489035236d7fb82e9467d` on Linux 6.1 x86-64 with Ruby 4.0.6, Go 1.27.0, PostgreSQL 15.19, pgvector 0.8.6, and Chrome for Testing 152: full `bin/ci` green including the native Linux isolation boundary, 547 Rails tests, 45 browser tests, three binary builds, runner contract, seeds, and SBOM. Focused release checks passed 14 tests for backup, verification, restore confirmation, upgrade preflight, the pgvector 0.8.1-to-0.8.6 boundary, and container privilege settings; a custom-format backup verified and restored in isolation.

### Milestone history

The build ran as a v1 stack of about 40 PRs (foundation, helpdesk, agent work, runtimes, memory, Intercom and Customer Success, operations) followed by next-phase milestones M0 rebaseline, M1 proofed resolutions and explainability, M2 dossier, M3 Support-to-renewal loop, M4 operational ownership and portability, M5 governed policy change, and M6 integrated proof (merged 28 August 2026 in PR #82, re-proven from code on 6 September 2026). M7 knowledge and research intake is the open milestone; its remaining items are in section 3. Per-milestone commit evidence up to M6 is preserved in the Git history of the retired roadmap file.

### 6–7 September 2026 knowledge and personal-account stack

Five stacked source branches, since merged as PRs #90–#94, cover DOCX intake, Intercom sync and applicability, connector policy/OAuth and Notion, Workspace search selection, and the personal Codex web companion. No production dependency was added. The checkpoints below were recorded before merge; they are not a release, deployment, or live-provider authentication claim.

The combined stack passed 954 Rails tests with 6,918 assertions on ssdnodes (Ruby 4.0.6, Go 1.27.0, PostgreSQL 18.6, pgvector 0.8.6). Two subsequently added deletion tests passed there with 41 assertions. Ruby/Go style, gem/importmap audits, Brakeman, mandatory Linux isolation tests, runner builds, the signed Rails–Go contract, seeds, and the 89-component SBOM check passed.

Running several browser suites concurrently overloaded the host and produced three timing failures. The complete current browser suite then passed locally with two workers: 75 tests, 1,268 assertions, no failures. Focused checks covered true 320-pixel layouts, keyboard access, native CSRF forms, Turbo, personal-account ownership and failed-start recovery. The initial overloaded browser run is not recorded as green.

A separate isolated PostgreSQL 16.10 server with pgvector 0.8.6 successfully loaded the final schema, rolled all seven new migrations down and up, applied each PR layer, and freshly loaded all four PostgreSQL 16-generated schema dumps. The deployed PostgreSQL version was not changed. Risk-based review used two internal review lenses and independent finding validation; findings were fixed and regression-tested. The external cross-provider pass was skipped because a non-Claude route could not be verified. No live OAuth or subscription credentials were consumed.

Stack checkpoints at their pre-merge feature commits:

| Branch | Feature commit | Rails tests / assertions | Browser tests / assertions | Check execution |
|---|---|---|---|---|
| `codex/word-imports` | `bab0985`, fixture correction `7ae58ac` | 879 / 6,580 | 67 / 1,159 | All native CI steps passed; browser rerun passed locally after host contention. |
| `codex/knowledge-sync` | `8d77d77` | 899 / 6,686 | 69 / 1,189 | Full isolated `bin/ci` passed on ssdnodes. |
| `codex/knowledge-connectors` | `686f59f` | 933 / 6,823 | 70 / 1,211 | Full isolated `bin/ci` passed on ssdnodes. |
| `codex/workspace-search` | `efa01fc` | 939 / 6,859 | 71 / 1,228 | Full isolated `bin/ci` passed on ssdnodes. |
| `codex/personal-ai-accounts` | `ac92b87` | 954 / 6,918 plus 2 / 41 | 75 / 1,268 | All native CI steps passed; full current browser suite passed locally after host contention. |

## 3. Pending work

Listed in the order they unblock a pilot. None of these blocks owner review of the current source.

1. **Finish guided-installer acceptance.** The installer is merged and natively tested, not released or deployed. Remaining local engineering: proof of scoped memory indexing and retrieval after `navishai configure memory`; and a scoped changed-image upgrade contract proven on a genuinely changed application image before the production rejection is relaxed. Remaining external outcomes: clean supported-host acceptance with real reboot and SSH loss, public DNS/ACME and renewal, external ingress isolation, an approved signing identity with trusted verification-key distribution and artifact hosting, and live ClamAV, SMTP, provider, and Supermemory validation.
2. **Native runtime search.** **Current no-go recorded 10 September 2026.** The four approved subscription protocols lack one or more required evidence fields: machine-readable run-bound HTTPS URL, bounded source excerpt, retrieval time, optional publication date, and rejectable terminal semantics. [The protocol record](./NATIVE_RUNTIME_SEARCH_PROTOCOL.md) pins each checked source revision and documents the limit. `web_search="disabled"` remains fixed, and parser tests reject a Codex query/action-only item as a non-retryable policy denial. Query events, action URLs, generated prose, inferred URLs, and opaque output cannot become citations or satisfy grounding. This applies only to the checked current protocols; a future adapter still needs a versioned typed result contract and approved egress profile. Parallel remains unimplemented.
3. **Legacy DOC image proof.** Native Linux conversion, isolation, the signed route, and focused browser states passed on 9 September 2026. Run the new manual workflow on a Docker-capable host to execute the built-image smoke; DOCX, PDF, Markdown, HTML, text and ZIP intake remain available.
4. **Live connector and personal-provider proof.** Intercom/Notion OAuth and shared sync need deployment credentials; personal Codex authentication needs a user's device-login approval. Automated suites use protocol fixtures and do not claim live account validation.
5. **Deferred by owner decision:** Helm parity with Compose and native Linux; S3-compatible object storage.

## 4. External boundaries

These need something outside the repository and are labelled as such rather than converted into passing evidence.

- **Hosts.** Production image construction, a live pgvector volume upgrade, the full Compose backup and isolated restore, and Compose upgrade preflight need a Linux host with Docker Engine and Compose v2. The runner isolation suite needs a kernel with Landlock and seccomp. A host that cannot reach Selenium Manager runs the browser suite with `CHROME_BIN`, `CHROMEDRIVER_BIN`, and, as root, `CHROME_ARGS="--no-sandbox"`.
- **Credentials.** Live OpenID Connect, SMTP, Intercom, SearXNG, Exa, Tavily, ClamAV, object-store, provider API-key, and subscription-runtime smoke tests need deployment-owned endpoints or credentials; the default suites use protocol fixtures.
- **Signing.** No release-signing identity exists. Manifests provide SHA-256 integrity, not signed provenance or a SLSA claim.
- **Automation.** GitHub Actions is manual-only and has not been used for this build; local checkpoints recorded here are the verification record.
- **Deployment ownership.** TLS, secrets, backup storage, restore rehearsal, firewall and namespace policy, an optional ClamAV daemon, and post-install checks belong to the operator. The self-hosted Supermemory Lite build has a 10,000-document cap.
- **Pilot and market.** No paid pilot or production adoption evidence exists. Pilot scope, customer approval, deployment, signing, and every market claim remain owner decisions.

## 5. Dated change decisions

Decisions taken after the build that changed scope, pins, or posture. Durable product and architecture decisions live in PRODUCT.md.

| Date | Decision |
|---|---|
| 27 August 2026 | Extend v1 with proofed resolutions, explainability, dossier, Support-to-renewal loop, operational ownership, portability, and governed policy change without expanding into a broad helpdesk or workflow platform; keep grounding strict while preserving attributable human communication authority; reuse the current integration for historical backfill and defer new named adapters until pilot evidence exists. |
| 6 September 2026 | In-app provider connections, the encrypted runner vault, and direct OpenAI and Anthropic API-key execution are an approved extension of the runtime registry under interview decision Q12. |
| 6 September 2026 | The macOS host-trusted execution mode is marked for redesign as a server-side companion boundary; it stays disabled by default and is recorded as an operator-accepted risk. |
| 6 September 2026 | Helm parity and S3-compatible object storage are deferred. Compose and native Linux with local storage remain the supported pilot deployments. |
| 6 September 2026 | SearXNG-only search, text-only knowledge uploads, and manual Help Center snapshots were gaps, not decisions. Exa and Tavily adapters and text, Markdown, HTML, PDF, and ZIP uploads shipped; Help Center sync, native search, and knowledge connections remain pending. |
| 6 September 2026 | Ship a reference ClamAV attachment-scanner adapter and a daily scheduled Account-health pass. |
| 6 September 2026 | Move the PostgreSQL pin from 15 to 16, pin the pgvector image at `0.8.6-pg16` by digest, and document the major-version upgrade. |
| 6 September 2026 | Approve the `pdf-reader` gem for PDF extraction; read ZIP bundles with a bounded standard-library reader rather than an archive gem. |
| 6 September 2026 | The landing page omits the template's pricing and testimonial sections until those exist and uses a content-fitted product preview instead of a fixed 16:9 media stage. |
| 6 September 2026 | Consolidate the build brief, roadmap, and release-candidate record into PRODUCT.md and this file. |
| 11 September 2026 | Move the Go development, module, host-preparation, and runner build pins from 1.27.0 to 1.27.1. Historical verification records retain the versions actually tested. |
| 11 September 2026 | Constrain the existing transitive `bigdecimal` gem to `>= 4.0` so it stays on its maintained line. Bundler therefore holds `ttfunk` at 1.7.0, because ttfunk 1.8.0 caps bigdecimal at 3.x; a later ttfunk release that accepts 4.x needs no Gemfile change. |
| 11 September 2026 | Keep rejecting changed-image `navishai upgrade` targets on main until a scoped supported path is implemented and proven on a genuinely changed application image; the experimental recovery evidence does not relax that guard. |
| 11 September 2026 | Cap the existing transitive `json` gem below 3.0. Active Support 8.1.3.1 passes `JSON.parse` options positionally, which json 3.0 rejects, so every jsonb attribute read raised `ArgumentError`. Remove the cap once a Rails release supports json 3. |

### Approved implementation scope — 6 September 2026

The owner approved immutable knowledge content versions with separate sync observations; complete-pass reconciliation and bounded resume; many-to-many product/Intercom applicability with human overrides; Admin-controlled search; separate Workspace connector enablement/service credentials and personal OAuth accounts; additive Notion intake; DOCX and legacy DOC intake; and a web companion whose execution stays on deployed Linux. Personal content must not become shared knowledge automatically. On 7 September 2026 the owner approved LibreOffice bundled into the package for isolated legacy DOC conversion. Native search requires structured result evidence before enabling an adapter. That implementation merged as PRs #90–#95. The checkpoint section records tests separately from deployment and live-provider proof.
