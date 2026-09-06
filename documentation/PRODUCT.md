# NavishAI product specification

**Status:** Consolidated product and architecture authority

**Consolidated:** 6 September 2026 from the v1 build brief (24 August 2026, interview decisions Q1–Q74), the next-phase roadmap (27 August 2026, milestones M0–M7), and the owner decisions recorded since. Implementation state and evidence live in [STATUS.md](./STATUS.md); this file says what NavishAI is and must do. When older notes conflict with this file, this file wins.

## 1. Outcome

NavishAI is an agent-first, human-governed customer-operations workspace for Support and Customer Success teams. Specialist AI crews investigate, retrieve, analyse, draft, review, and remember. Humans keep customer communication and every consequential decision.

- **Support is the entry product.** NavishAI sits beside Intercom and shared email and also provides a focused native helpdesk. A human team receives, triages, investigates, drafts, reviews, and sends high-quality responses with proof.
- **Customer Success is the retention value.** NavishAI connects cases, conversations, notes, account data, health signals, and memory to identify renewal risk, recommend interventions, and connect human-owned interventions to observed outcomes without claiming causation.
- **Accountable resolution record.** Every material recommendation, draft, decision, intervention, and recovery action must be explainable from durable evidence, without turning NavishAI into a broad inbox, chatbot, or workflow platform.

The initial buyer is a founder-led or small B2B SaaS company, with a credible path to mid-market controls. Validation runs through self-use, an approved employer pilot, and a small paid private beta of design partners. The first release is self-hosted with full capability; a managed offering, billing integration, and any public launch are separate owner decisions.

## 2. Scope

### Included

- True multi-organisation tenancy with multiple isolated Workspaces per Organisation.
- Email/password authentication with verification, reset, invitations, generic OpenID Connect, and a protected local break-glass administrator.
- Owner, Admin, Manager, Member, and Viewer roles.
- A focused native helpdesk: Accounts, Contacts, source identities, conversations, cases, assignment, status, SLA, private notes, drafts, threading, attachments, replies, and audit history.
- Shared email as the first owned channel; two-way Intercom sync for conversations, Contacts, companies, assignment, tags, and notes; historical Intercom backfill through the same read-only boundary.
- Human-only sending to shared email and Intercom.
- Opinionated Support and Customer Success crew templates with bounded configuration; durable tasks, handoffs, evidence, runs, reviews, failures, retry, cancellation, and cost attribution.
- Admin-approved runtime registry: subscription CLI adapters for ChatGPT/Codex, Claude, Grok, and Cursor; direct OpenAI and Anthropic API-key connections configured in the app and held in a runner-local vault; a capability-based registry for more.
- Read-only public-web search through SearXNG or an approved hosted provider, and guarded extraction.
- PostgreSQL full-text search and pgvector retrieval; self-hosted Supermemory behind a replaceable memory contract.
- Typed, versioned resolution contracts, deterministic claim grounding with cite-or-refuse, human-edit attribution, Explain this outcome, and honest usage, budget, and cost rollups.
- A source-backed Account dossier, typed business-evidence intake, deterministic account-health signals including Support evidence, renewal-risk investigation, human-owned interventions with observed outcome reviews, and a conversational scorecard designer.
- A reliability and recovery cockpit, verified Workspace archive round trips, and governed policy change with preview, explicit canary, versioning, and rollback.
- Knowledge sources from maintained text, URL snapshots, uploaded documents (text, Markdown, HTML, PDF, ZIP bundles), and Intercom Help Center.
- In-app notifications, email notifications, and configurable signed outbound webhooks.
- Docker Compose and native Linux as supported deployments; an experimental cloud-neutral Helm chart.
- Workspace export/import, retention controls, backup/restore, upgrade preflight, malware scanning through a deployment-run scanner, and auditable security controls.

### Excluded

- Autonomous, scheduled, bulk, confidence-threshold, or standing-permission customer sends.
- A customer chat widget, public help centre, social channels, campaigns, marketing automation, or a general omnichannel suite.
- Bot deflection, autonomous ticket closure, or AI resolution-rate claims.
- Replacing every Intercom surface. Intercom stays authoritative for its native conversation; NavishAI owns agent work, evidence, memory, review, and its human-send audit.
- SAML, SCIM, native mobile apps, multi-region hosting, provider-specific infrastructure modules, or provider-specific Terraform.
- NavishAI-managed Supermemory or silent fallback to any managed memory service.
- Billing, invoicing, subscription enforcement, or chargeback.
- Claims of SOC 2, HIPAA, ISO 27001, or any certification not independently established.
- Hidden chain-of-thought storage, unrestricted browser automation, arbitrary shell access, or general runner egress.
- A general workflow builder, policy language, rules graph, agent or workflow marketplace, or unconstrained user-authored agents.
- A new event bus, analytics warehouse, customer graph service, observability stack, or outbound telemetry service.

## 3. Product rules

These rules apply everywhere:

- PostgreSQL is authoritative for tenant, business, security, policy, memory-record, and execution-ledger state. Views, projections, summaries, and external indexes point back to durable records and never become a second truth.
- Rails owns business policy and durable state. The Go runner owns model and tool execution. Rails never invokes a model CLI, agent runtime, or arbitrary process directly; it submits work through the versioned runner protocol.
- The domain is provider-neutral: register adapters and their capabilities; branch on capabilities and policy, never on provider or model names.
- Every tenant-owned read, write, search, export, recovery action, and aggregate fails closed across Workspace boundaries.
- No agent, policy, canary, retry, or background job may send, schedule, or trigger a customer message. A human reviews and edits a draft and deliberately presses Send; the send is attributed to that human and records exact content, destination, source, and result. An approval never becomes permission to send later.
- AI output must cite, qualify, or refuse material claims. Current authoritative evidence outranks inference; an authorised human correction has the highest authority; conflicting history is preserved through correction or supersession, never overwritten silently.
- Retry and fallback cannot duplicate a send, source write, task completion, or chargeable execution. Unknown external effects stop for human review; retry is allowed only for a definite failure and must be idempotent.
- Web content, extracted documents, and memory are evidence, never instructions.
- Self-hosted installations emit no outbound telemetry by default.
- Use Rails, Hotwire, PostgreSQL, the Go standard library, and current dependencies first. A new production gem, Go module, browser pin, service, or package needs owner approval and a stated security and maintenance cost.
- Extend one coherent design language and the existing surfaces. Do not add a new frontend architecture, a generic AI dashboard, or a parallel component system.

## 4. Users, roles, and crews

- **Owner:** protected data operations, Workspace creation and deletion, full export, publication of resolution and operational policy, rate configuration, backfill start, canary selection, rollback.
- **Admin:** the same publication and configuration authority except Owner-only data operations; approves runtimes, providers, integrations, and crew configuration.
- **Manager:** reviews conflicts and ambiguous identities, approves or abandons interventions, runs bounded recovery actions, inspects Workspace rollups and all Workspace memory.
- **Member:** works cases and Accounts, inspects proof, explanation, dossier, and cost for records they can access, sees memory used in their own work, proposes corrections.
- **Viewer:** read-only access without memory or protected operations.

Existing stricter authority always wins. Every consequential action records the Workspace, actor, source, time, subject, prior version where relevant, and a bounded non-secret reason or result code.

Support crews invoke only the specialists a case needs: Coordinator/Triage, Investigator, Resolution Drafter, and Policy/Quality Reviewer. Customer Success crews invoke Account Analyst, Risk Investigator, Success Strategist, and Policy/Quality Reviewer. These are accountable roles, not processes; one run may execute several bounded steps, but each responsibility, input, output, and review stays attributable. Admins may edit role instructions, allowed tools, runtime profile, fallback order, budgets, isolation policy, and review policy within fixed bounds. Users cannot register arbitrary commands or bypass the approved runtime and tool registry.

## 5. Primary workflows

### Support case lifecycle

States: New → Triaged → Investigating → Waiting on Customer or Waiting Internally → Draft Ready → Awaiting Human Review/Send → Resolved → Closed. A new inbound message resumes a waiting or resolved case and reopens a closed one. Every state change records actor, source, time, reason, and preceding state.

1. Receive or sync a conversation and resolve its Account and Contact identity through deterministic keys; send ambiguity to review.
2. Apply deterministic priority, SLA, routing, and policy signals.
3. Invoke only the needed specialists.
4. Collect internal records, approved knowledge, current conversation evidence, scoped memory, and public-web evidence.
5. Produce a cited investigation and response draft under the published resolution contract.
6. Evaluate grounding deterministically: every material claim is supported, uncertain, conflicted, or refused; a blocking contract result cannot become Draft Ready or receive an approved quality review and is preserved as inspectable failed work.
7. Let an authenticated human inspect and edit the draft; a human edit is attributed and does not retroactively ground the AI artifact.
8. Send only when that human deliberately presses Send, with a frozen delivery, idempotency, recipient checks, and unknown-outcome review.
9. Consolidate eligible memory at correction, resolution, and closure.

### Customer Success lifecycle

Account health uses Intercom history, shared email, NavishAI notes, and typed Account inputs imported through CSV or the authenticated API (append-only, source-identified, idempotent).

1. Recalculate deterministic signals when inputs change, on the daily schedule, and inside renewal windows. Show every signal, value, source, time range, weight, risk points, and citation; keep AI text out of score calculation.
2. Open a risk investigation only for a material change, a renewal window, or a human request. The crew adds a bounded narrative, likely causes, evidence, uncertainty, and recommended interventions, visibly separate from deterministic facts.
3. Store interventions separately from crew narratives with the states proposed, approved, completed, abandoned, and reviewed. A Manager-or-higher human approves or abandons; completion is a human action that never sends customer communication; review freezes before-and-after facts and reports association, not cause.
4. Let teams design scorecards conversationally, convert the proposal to a deterministic versioned definition, preview and backtest it, and let an Admin publish or roll back without rewriting prior assessments.

### Explain this outcome and the dossier

- One read-only explanation over authoritative records, reachable from a case, Account, run, or health assessment, shows the applied contract, completion state, claims and evidence, freshness, conflicts, uncertainty, task and run lineage, memory selected, runtime selection and fallback reason, reviews, draft versions, human edits, failures, recovery actions, and the final human action. It never exposes hidden reasoning, prompts, secrets, or another Workspace.
- The Account dossier is a query over Accounts, Contacts, identities, conversations, cases, evidence, governed memory, corrections, tasks, health facts, interventions, and outcomes, organised around identity, relationship, verified facts, recent conversations, recurring issues, commitments, health, unresolved conflicts, and the next human-owned action. Generated summaries are disposable views that link to the facts they used.

### Usage, budget, and cost

Derive observed input units, output units, search cost units, and budget consumption from run and search ledgers by run, case, and Account. Money appears only from an adapter-reported amount or a bounded Admin-configured rate whose provenance and version are frozen on the run; unknown cost is never shown as zero. Cost is informational, never billing.

## 6. Architecture

    Browser
      |
    Rails + Hotwire control plane
      auth, tenancy, roles, policy; helpdesk, Customer Success, administration;
      jobs, notifications, integrations; authoritative PostgreSQL state
      |  versioned authenticated runner protocol
    Go execution runner
      approved adapter and tool registry; process isolation, timeouts, cancellation;
      capability detection and canonical events; run-scoped credentials and egress policy
      +--> approved subscription CLIs and direct provider APIs
      +--> approved public-search adapters
    Rails/PostgreSQL
      +--> self-hosted Supermemory through a provider-neutral contract
      +--> SMTP and shared inbox, Intercom, object storage, outbound webhooks

**Rails control plane.** Server-rendered ERB, Turbo, and small Stimulus controllers; import maps and self-hosted assets with no Node application or build pipeline; plain product CSS with a token and component layer; the Rails authentication generator as the local-auth base; Active Job on the database-backed queue; PostgreSQL-backed application, queue, cache, and cable state; Minitest and Rails system tests.

**Go execution runner.** Standard library first. It owns versioned run admission and idempotency, runtime detection and capability reporting, process start, supervision, timeout, cancellation, and reaping, allowed roots, deployment-appropriate isolation and resource limits, run-scoped credential delivery, tool and outbound-network policy, canonical event normalisation, usage observations, and health, readiness, and compatibility status. The deterministic scripted adapter proves the protocol without a model.

**PostgreSQL authority.** Organisations, Workspaces, Users, roles, invitations, sessions; Accounts, Contacts, identities, conversations, cases, messages, attachments, notes, tags, SLA state; crew templates, agent profiles and versions, tasks, handoffs, runs, events, evidence, artifacts, reviews, drafts, sends; runtime approvals, provider configuration fingerprints, tool policies, budgets, routing decisions, governed policy versions, and audit events; knowledge sources and versions; scorecards, signals, assessments, interventions, and outcomes; memory records, proposals, corrections, tombstones, and index state; operational checks, backfill runs, and archive verification results.

**Domain invariants.** Agent identity is separate from runtime adapter, provider account, model, task, run, session, or event. Provider conversations are optional continuity, never business state. Durable tasks, evidence, reviews, and decisions are the work record; hidden agent chat is not. Every tenant-owned row is scoped through the active Workspace. Cross-Workspace memory, search, retrieval, and execution are denied by default.

## 7. Runtimes, providers, and public-web research

- Each approved installation records adapter key and protocol version, resolved executable path and version or the built-in HTTPS transport, non-secret account metadata, declared capabilities and compatibility status, execution mode, allowed Workspaces, roles, tools, data classes, and budgets, health, last check, and known incompatibility reason. Approval requires a passing runtime test of the exact configuration fingerprint; a configuration change invalidates test and approval evidence.
- Subscription credentials stay on the customer-controlled runner; NavishAI detects and invokes an authenticated CLI but never imports, copies, displays, or stores its login token. API keys cross Rails only in the synchronous signed configure request and live in the encrypted Workspace-scoped runner vault; Workspace deletion purges them first.
- Runtime selection is a Workspace default with optional per-agent override and an ordered fallback profile. Fallback is allowed only when capability, data policy, Workspace, approval, isolation policy, and task semantics remain compatible; the selected runtime and reason are recorded and disclosed. Detect versions against maintained compatibility ranges; warn or block known incompatibilities; never auto-upgrade a customer's CLI.
- Execution modes: `bounded` for the runner's built-in HTTPS provider client, `strong_isolated` for Linux subscription CLIs under Landlock, seccomp, namespaces, resource limits, and a deny-by-default egress profile bound to the exact approved executable, and `host_trusted` for host-run modes that lack kernel isolation and must be explicitly enabled by the deployment owner. Every run freezes its mode and isolation policy.
- Classify and minimise data before execution; runtime and tool policy decides which data classes an adapter may receive; the UI shows the selected runtime, disclosed data classes, evidence returned, and policy or fallback reason without copying prompts into logs.
- Public-web search is a typed `web_search` tool behind a provider-neutral registry with SearXNG as the self-hosted default and hosted adapters (Exa, Tavily) as options that keep their API key on the runner. A runtime's native search is a further option only when the run's egress profile permits it and results are auditable and structured. Queries are minimised and redacted; results are normalised with URL, excerpt, publication and retrieval dates, citation, policy decision, and cost; evidence links are HTTPS only.
- `web_extract` is a separate guarded capability: block loopback, private, link-local, metadata, cluster, and reserved addresses; revalidate DNS and redirects; limit time, size, and MIME type; strip active content; send no ambient credentials. Interactive or authenticated browsing is out of scope.

## 8. Memory and retrieval

- A provider-neutral internal memory contract with self-hosted Supermemory as the first engine for both self-hosted and any future managed NavishAI; never the managed Supermemory service.
- Four typed classes: episodic, semantic, profile, and procedural. Every record has a source, observed and valid times, scope, confidence, retention rule, and supersession state. Scopes are Organisation, Workspace, Account, Contact, case, crew, agent, and user with controlled inheritance inside one Workspace.
- Episodic records are captured continuously in the source transaction. Agents propose semantic facts and preferences; a Manager, Admin, or Owner accepts them. Only authorised humans publish procedural memory. Consolidation happens at closure, review, correction, outcome, and scheduled curation.
- Context assembly uses a fixed budget, scope and relevance ranking, separates memory from current evidence, cites every retrieved item, freezes the selection on the run, and never persists chain of thought.
- Admins and Managers inspect scoped memory; Members inspect memory used in their work; authorised users propose corrections; sensitive access is audited. Tombstones remove records from retrieval immediately and track external removal.
- Degraded mode when the engine is unavailable: preserve authoritative writes and deterministic workflows, stop capture and recall explicitly, warn users and operators, queue idempotent indexing retries, block only memory-critical work, and never fall back to a managed provider. PostgreSQL facts must be sufficient to reconstruct the external index.

## 9. Helpdesk, identity, knowledge, and integrations

- **Accounts and Contacts.** Represent source identities under NavishAI Accounts and Contacts; match only on exact normalised email or domain keys inside one Workspace; block ambiguity for Manager-or-higher review; audit and allow reversal of merges.
- **Shared email.** Receive through a signed forwarding webhook with bounded size and skew; preserve threading identifiers and the original source; send plain text over SMTP only after a fresh authenticated human Send.
- **Intercom.** Two-way sync of conversations, Contacts, companies, assignment, tags, and notes through signed webhooks plus cursor reconciliation; remote state stays a visible source fact; customer-facing writes need a fresh human action. Historical backfill uses GET requests only, a confirmed dry-run manifest, bounded resumable batches, identity review, and a preservation report.
- **Attachments.** Bounded count, size, and total; byte-signature content detection; quarantine until a deployment-selected scanner returns clean; malware scanning through the ClamAV reference adapter or a replacement; authorised download; local storage today with S3-compatible storage deferred.
- **Knowledge.** Approved sources are maintained text, HTTPS URL snapshots, uploaded documents (text, Markdown, HTML, PDF, and ZIP bundles of them, each scanned and reduced to a plain-text snapshot with the original retained), and Intercom Help Center articles. Track source, version, retrieval or sync time, expiry, and deletion; warn on stale or deleted material; current authoritative content beats memory. Help Center synchronisation and provider-backed knowledge connections are planned; see STATUS.md.

## 10. Security, privacy, and enterprise readiness

Design for evidence useful to SOC 2, HIPAA-aligned deployments, ISO-style controls, and enterprise questionnaires without claiming any certification.

- Deny-by-default Workspace authorisation in controllers, jobs, channels, search, memory, integrations, and runner requests.
- Encrypted application secrets; CLI credentials on the runner; scoped just-in-time execution material; audit of authentication, role, policy, runtime, data disclosure, memory, integration, human-send, export, retention, and administrator actions without logging secret values.
- Tenant-configurable content retention, separate append-only security and approval audit retention, export and deletion workflows, and tombstones where a retained audit record cannot be erased.
- Signed and protected webhooks, replay prevention, idempotency, bounded retries, and dead-letter visibility.
- CSRF, session fixation, rate limiting, open redirect, SSRF, injection, unsafe rendering, attachment, and privilege-escalation coverage.
- A maintained threat model ([THREAT_MODEL.md](./THREAT_MODEL.md)) covering browser, Rails, queue, PostgreSQL, runner, CLI processes, providers, search and extraction, Supermemory, email, Intercom, object storage, knowledge intake, recovery, backfill, policy change, and updates.
- Dependency pinning, lockfiles, provenance review, automated vulnerability checks, an SBOM for releases, and a documented patch policy ([RELEASE.md](./RELEASE.md)).
- Deployment isolation: a dedicated runner container without a Docker socket on Compose; a dedicated service account and process boundary on native Linux; separate runner workloads on Helm; allowed roots, resource bounds, timeouts, cancellation, scoped credentials, and explicit egress policy in every mode.

## 11. Experience requirements

NavishAI is a calm operating workspace, not a dashboard of bots. Primary surfaces: inbox and case queue; case workspace with conversation, facts, crew progress, evidence, memory, review, draft, and Account context; Accounts and Contacts with the dossier; account health and renewal-risk workspace; scorecard designer and history; knowledge and memory inspection; crew, runtime, provider, search, integration, security, retention, policy, and Workspace administration; reliability cockpit; Explain this outcome; and a public product page.

Use progressive disclosure: show the current decision, source, uncertainty, blocker, and next action before raw ledger detail. Every meaningful surface covers loading, empty, partial, stale, degraded, permission-denied, validation, integration-failure, runtime-failure, blocked, review, and success states. Support keyboard navigation, visible focus, semantic HTML, screen readers, reduced motion, a 320-pixel minimum layout, and safe text wrapping. The design language is in [DESIGN.md](./DESIGN.md).

## 12. Deployment and operations

- **Docker Compose** and **native Linux** are supported; **Helm** is experimental until it has the same upgrade, backup, and security evidence. No provider-specific Terraform.
- Pinned toolchain: Ruby 4.0.6, Rails 8.1, Go 1.27, PostgreSQL 16 with pgvector 0.8.6, Supermemory Local 0.0.8. Exact records are in [DEPENDENCIES.md](./DEPENDENCIES.md).
- Backups cover PostgreSQL, uploaded files, runner state including the provider vault, configuration and secret references, and Supermemory state or deterministic reconstruction; coordinated backup, verification, restore, restore-test, upgrade-preflight, and major-version upgrade procedures are in [OPERATIONS.md](./OPERATIONS.md).
- Releases use pinned artifacts, checksums, signatures where a release identity exists, migration preflight, backups, compatibility checks, upgrade tests, and explicit rollback boundaries. Never silently upgrade a CLI, database, memory service, or infrastructure component.
- Operators diagnose connector, execution, send, indexing, retention, archive, backup, restore, and preflight state from the role-gated reliability cockpit and invoke only bounded, audited recovery actions.

## 13. Working agreements

The delivery rules in [AGENTS.md](../AGENTS.md) apply: framework-native capabilities first, owner approval for new production dependencies, atomic Conventional Commits, small green PRs, repository-native checks, visual inspection of meaningful UI at desktop and mobile widths, and short handoffs that distinguish planned, built, tested, merged, released, deployed, and verified. Update this specification only when a durable product or architecture decision changes; record implementation state and dated change decisions in STATUS.md.
