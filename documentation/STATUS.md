# NavishAI implementation status

**Status:** Single record of what [PRODUCT.md](./PRODUCT.md) requires, what exists, the evidence, and what remains

**Updated:** 6 September 2026

NavishAI is build-complete and pilot-ready for owner review. That describes the source stack, not a published package, launch, live deployment, certification, product validation, or market result. Update this file when implementation state, evidence, or a dated decision changes; do not reopen the specification here.

## 1. Capability matrix

Status values: **Done** (implemented, tested, merged), **Partial** (part of the requirement exists; the gap is named), **Deferred** (owner decision to postpone), **Planned** (specified, not started), **External** (needs a host, credential, legal, signing, or market step outside the repository).

### Foundation and security

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Multi-organisation tenancy with isolated Workspaces | Done | `Organization`, `Workspace`, `Membership`, `WorkspaceAuthorization` | Cross-Workspace access fails closed in controllers, jobs, search, memory, integrations, and runner requests. |
| Local auth, verification, reset, invitations, first-Owner bootstrap | Done | `SessionsController`, `VerificationsController`, `PasswordsController`, `WorkspaceInvitations*`, `FirstOwnerBootstrap` | Bootstrap closes after first use. |
| Generic OpenID Connect | Done | `OidcProvider`, `OidcSessionsController` | Code flow with PKCE, state, nonce, exact issuer, allowlisted algorithms; binds only an existing verified User. |
| Protected break-glass administrator | Done | `BreakGlassSessionsController`, `navishai:break_glass:create` | Loopback-only route, deployment token plus password, 15-minute sessions. |
| Owner, Admin, Manager, Member, Viewer roles | Done | `Membership::ROLES` | Role matrix enforced in controllers and services. |
| Append-only audit, secure headers, filtered parameters, rate limits | Done | `AuditEvent`, `Auditing`, `SecurityRateLimits`, CSP initializer | PostgreSQL rejects audit updates and deletes. |
| Application shell, design language, standard states | Done | `app/views/layouts`, `app/assets/stylesheets`, [DESIGN.md](./DESIGN.md) | Desktop, tablet, 390-pixel, and 320-pixel browser coverage; keyboard focus, reduced motion, CSP without inline styles. |
| Threat model tied to implemented controls | Done | [THREAT_MODEL.md](./THREAT_MODEL.md) | Includes contract bypass, forged claims, human-edit attribution, cost tampering, dossier leakage, evidence-ingest forgery, intervention authority, recovery, backfill, policy preview, canary, rollback, provider credentials, hosted search keys, document intake, and host-trusted mode. |

### Native helpdesk

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Accounts, Contacts, deterministic identity matching, ambiguity review, reversible merge | Done | `CustomerIdentityGraph`, `SourceIdentityResolver`, `IdentityMatchReview`, `CustomerRecordMerger` | Exact email and domain keys only. |
| Conversations, messages, cases, lifecycle, assignment, tags, notes, priority, resume and reopen | Done | `CaseWorkflow`, `SupportCase`, `SupportCaseStatusChange`, `ConversationThread` | Every transition records actor, source, time, reason, prior state. |
| Inbox and case workspace UX | Done | `SupportCasesController`, `support_cases` views | Queue filters, history, responsive conversation view, next-action rail, concise Account context. |
| SLA engine with calendars, holidays, pause, warnings, escalation | Done | `SlaEngine`, `ServiceCalendar`, `SlaPolicy`, `CaseSla`, `SlaEscalationTask` | Boundary-time deterministic tests. |
| Shared-email intake with signed webhook, threading, duplicate suppression | Done | `SharedEmailIntake`, `Webhooks::SharedEmailController`, `InboundEmailDelivery`, `EmailThread` | 10 MiB source, 1 MiB text, five-minute skew. |
| Human-only email send with attribution, idempotency, unknown-outcome review | Done | `HumanEmailSend`, `HumanSendAuthorization`, `OutboundEmailDelivery`, `EmailRepliesController` | No agent or job entry point; retry cannot duplicate. |
| Attachments with sniffing, limits, quarantine, authorised download | Done | `AttachmentIntake`, `StoredAttachment`, `AttachmentDownloadsController` | PDF, text, PNG, JPEG, GIF by signature; 5 MiB per file, 10 MiB per message. |
| Malware-scan contract and reference adapter | Done | `AttachmentScanner`, `AttachmentScanner::Clamd` | ClamAV INSTREAM adapter selected by `NAVISHAI_ATTACHMENT_SCANNER=clamd`; default keeps every file quarantined. |
| S3-compatible object storage | Deferred | `config/storage.yml` | Owner deferral on 6 September 2026; only the local disk service is configured and tested. |
| Knowledge: maintained text, URL snapshots, versions, freshness, expiry, full-text search, citations | Done | `KnowledgeIngestion`, `KnowledgeUrlFetcher`, `KnowledgeSearch`, `KnowledgeSource(Version)` | SSRF-safe fetch, immutable versions, stale and deleted warnings. |
| Knowledge document uploads: text, Markdown, HTML, PDF, ZIP bundles | Done | `KnowledgeDocumentExtractor`, `KnowledgeZipBundle`, `pdf-reader` | One source per bundled document; bounded pages, bytes, entries; CRC-verified archive reader. |
| Intercom Help Center as a synchronised knowledge source | Partial | `KnowledgeIngestion#ingest_integration!` | Articles are registered as manual snapshots by ID. Read-only synchronisation through the Intercom connection is planned (section 3). |
| Provider-backed knowledge connections (for example Notion) | Planned | | Specified in section 3; no implementation. |

### Durable agent work and runtimes

| Requirement | Status | Where | Notes |
|---|---|---|---|
| Support and Customer Success crew templates, bounded agent profiles and versions | Done | `CrewConfiguration`, `AgentPolicy`, `AgentProfile(Version)` | Eight fixed roles; Admin-editable within bounds; non-admins cannot expand authority. |
| Durable tasks, handoffs, dependencies, comments, evidence, reviews, cancel, retry | Done | `CrewWork`, `CrewTask`, `CrewTaskEvent`, `CrewTaskDependency`, `CrewEvidenceResolver` | Refresh and retry preserve state. |
| Versioned runner protocol with signed requests, admission, idempotency, health | Done | `RunnerClient`, `RunnerProtocol`, `runner/internal/{protocol,admission}` | HMAC-signed requests, five-minute skew, `POST /v2/runs/admit`, `/livez`, `/readyz`; Rails-to-Go contract check in `script/runner_contract`. |
| Deterministic scripted adapter | Done | `runner/internal/scripted` | Success, retry, timeout, cancellation, malformed output, policy denial. |
| Run ledger, ordered events, replay, attempts, usage, terminal rules | Done | `ExecutionLedger`, `ExecutionRun`, `ExecutionEvent`, database triggers | Duplicate and out-of-order events rejected by PostgreSQL functions. |
| Execution supervision: roots, limits, timeout, cancellation, reaping, credentials, egress | Done on Linux | `runner/internal/supervisor`, `runner/internal/isolation`, `navishai-exec`, `navishai-netns-launch` | Landlock, seccomp, namespaces, resource limits, deny-by-default egress profiles bound to the exact executable. |
| macOS host-trusted execution for Codex and Cursor | Partial | `runner/internal/adapters/cursorhost`, `RuntimeInstallation` execution modes | Works as an explicitly enabled `host_trusted` mode without kernel isolation. Owner marked it for redesign as a server-side companion boundary on 6 September 2026; treat as operator-accepted risk until then. |
| Investigation, drafting, quality review, artifacts, change requests, reruns | Done | `CrewArtifactPublisher`, `CrewArtifact`, `CrewWork` review commands | Strict artifact schema with citations, uncertainty, conflicts, versions. |
| Execution UX and recovery | Done | `ExecutionRunsController`, `ExecutionRecovery`, run panel views | Live progress, blocked, degraded, failed, canceled states; reconcile and retry. |
| Runtime approval registry with detection, fingerprints, tests, compatibility | Done | `RuntimeRegistry`, `RuntimeInstallation`, `RuntimeInstallationsController`, `runner/internal/runtimecatalog` | Approval requires a passing test of the exact configuration fingerprint. |
| Codex, Claude, Grok (ACP), Cursor (ACP) subscription adapters | Done | `runner/internal/adapters/{codex,claude,grok,cursor}` | Mocked contracts plus opt-in live smoke tests that consume the operator's subscription. |
| Direct OpenAI and Anthropic API-key connections | Done | `ProviderConnectionGateway`, `ProviderConnectionsController`, `runner/internal/{providerapi,providerconfig}` | Owner-approved extension of interview decision Q12; keys live only in the encrypted runner vault. |
| Routing, fallback, budgets, disclosure, hard stops | Done | `RuntimeRouter`, `UsageCostCapture` | Incompatible fallback denied with a visible reason; adapters stop at unit caps. |
| Public-web search: SearXNG | Done | `runner/internal/websearch`, `PublicWebResearch` | Self-hosted default. |
| Public-web search: hosted providers | Partial | `runner/internal/websearch/hosted.go` | Exa and Tavily implemented with runner-held keys. Parallel is not implemented. Native runtime search and per-Workspace provider selection are planned (section 3). |
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
| Check-host preparation for ephemeral environments | Done | `script/prepare_check_host`, `.claude/hooks/session-start.sh` | Builds pinned pgvector and Ruby from source when download hosts are blocked. |

## 2. Evidence

`bin/ci` is the source checkpoint: Ruby and Go style, gem and Importmap audits, Brakeman, the full Rails and browser suites, Go vet and tests with the process-isolation suite required, the Rails-to-runner contract, seeds, and the SBOM check. Record host omissions rather than treating a partial run as green.

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

### 27 August 2026 rebaseline

From `fbf65f0b3c268f650a2489035236d7fb82e9467d` on Linux 6.1 x86-64 with Ruby 4.0.6, Go 1.27.0, PostgreSQL 15.19, pgvector 0.8.6, and Chrome for Testing 152: full `bin/ci` green including the native Linux isolation boundary, 547 Rails tests, 45 browser tests, three binary builds, runner contract, seeds, and SBOM. Focused release checks passed 14 tests for backup, verification, restore confirmation, upgrade preflight, the pgvector 0.8.1-to-0.8.6 boundary, and container privilege settings; a custom-format backup verified and restored in isolation.

### Milestone history

The build ran as a v1 stack of about 40 PRs (foundation, helpdesk, agent work, runtimes, memory, Intercom and Customer Success, operations) followed by next-phase milestones M0 rebaseline, M1 proofed resolutions and explainability, M2 dossier, M3 Support-to-renewal loop, M4 operational ownership and portability, M5 governed policy change, and M6 integrated proof (merged 28 August 2026 in PR #82, re-proven from code on 6 September 2026). M7 knowledge and research intake is the open milestone; its remaining items are in section 3. Per-milestone commit evidence up to M6 is preserved in the Git history of the retired roadmap file.

## 3. Pending work

Listed in the order they unblock a pilot. None of these blocks owner review of the current source.

1. **Intercom Help Center synchronisation.** Replace manual article snapshots with read-only sync through the existing Intercom connection, reconciliation cursor, and signed-webhook boundary: one Knowledge source per published article keyed by remote article ID and updated time, stale-then-deleted handling for unpublished articles, bounded pages, bytes, and time, and review stops instead of silent truncation. Evidence: create, update, unpublish, delete, cursor resume, and cross-Workspace denial without any remote write.
2. **Search: per-Workspace provider selection and native runtime search.** Let a Workspace choose an approved provider from the runner catalog (a provider is unavailable until the deployment enables it), and allow a runtime's native search only when the run's egress profile permits it and results are auditable, structured, and pass the same citation contract. Parallel remains unimplemented.
3. **Provider-backed knowledge connections.** One connection kind chosen from pilot evidence (for example Notion), registered through the in-app connection flow and runner-held vault, importing pages as Knowledge source versions with the same provenance, freshness, and deletion rules as uploads. No generic connector SDK.
4. **Host-trusted execution redesign.** Replace the macOS host-trusted mode with a server-side companion boundary; until then the mode stays disabled by default and is recorded as an operator-accepted risk.
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

### DOCX intake — 6 September 2026

DOCX intake is implemented using the existing bounded ZIP reader and XML parser, preserving scanning, quarantine, original attachments, and existing text, Markdown, HTML, PDF, and ZIP intake. Macro-bearing, encrypted, malformed, oversized, and unsupported embedded-content packages are rejected. Legacy DOC conversion remains pending approval of an isolated converter dependency. This checkpoint is unmerged.
