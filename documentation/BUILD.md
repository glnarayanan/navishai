# NavishAI build brief

**Status:** Canonical product decision and implementation plan

**Decision date:** 24 August 2026

**Selected architecture:** Rails + Hotwire + PostgreSQL control plane, Go execution runner
**Delivery target:** A market-review-ready v1 through one autonomous stack of roughly 40 small PRs

This is the durable outcome of the NavishAI ideation conversation and the Q1-Q74 product interview. It replaces the earlier six-PR synthetic-proof plan. It is a decision record and executable build guide, not a verbatim transcript. When older notes conflict with this file, this file wins.

## Start Amp in one message

Use this after the repository has a Git remote and Amp has the required plugins available:

> Read AGENTS.md and documentation/BUILD.md completely. Build the market-review-ready NavishAI v1 described there. Work autonomously through the ordered PR stack; do not stop after each PR or wait for routine approval. Keep every commit Conventional and atomic, and every PR small, green, reviewable, and stacked on the preceding PR. Preserve the settled decisions and use framework-native capabilities first. For meaningful UI work, use Impeccable, Ui.sh, and only the relevant Matt Pocock skills. Run the stated checks and inspect the UI at desktop and mobile sizes before advancing. Push green checkpoints. Stop only for a material blocker defined in the brief, then report the exact evidence and smallest decision required.

Amp already knows how to use its local and Orb environments. The repository must not teach Amp how to operate Amp, assume an absolute checkout path, or make NavishAI depend on the coding agent used to build it.

## 1. Outcome

NavishAI is an agent-first, human-governed customer-operations workspace. It gives Support and Customer Success teams coordinated specialist AI crews, durable work, evidence, memory, review, and human-controlled customer communication.

Support is the entry product. NavishAI begins beside Intercom and shared email, while also providing a focused native helpdesk. Customer Success is the long-term renewal value: account health, renewal-risk investigation, evidence-backed recommendations, and customer-specific scorecards.

The first release is open source and self-hostable. A managed offering and Dodo Payments come only after the owner validates demand through personal use, an approved employer pilot, and external design partners.

### Build-complete definition

The v1 build is complete and ready for owner review when all planned v1 capabilities below exist, work together end to end, and pass the repository's security and UX checks. A live pilot is useful validation but is not a gate that leaves Amp waiting indefinitely.

A reviewer must be able to:

- Install NavishAI through supported Docker Compose or native Linux instructions.
- Bootstrap the first Owner, create an organisation and isolated workspaces, invite users, and enforce the defined roles.
- Configure only Admin-approved model CLIs, search providers, email, Intercom, object storage, and memory infrastructure.
- Receive a shared-inbox email, sync an Intercom conversation, create or update the matching Account and Contact, and work the case in NavishAI.
- Run a Support Case Crew that triages, investigates, cites evidence, uses approved public-web search, recalls scoped memory, and prepares a response draft.
- Review and edit the draft, then have an authenticated human deliberately press Send. No agent can send, schedule, or trigger a customer message.
- Inspect an attributable history of tasks, runs, evidence, memory used, reviews, edits, sends, failures, retries, and actors.
- Recalculate account health from deterministic signals, investigate material risk changes, and produce evidence-linked Customer Success recommendations.
- Draft, preview, backtest, publish, version, and roll back an account-health scorecard through the guided scorecard designer.
- Continue core case work in an explicit degraded mode when Supermemory or a model runtime is unavailable.
- Export workspace data, restore a documented backup, and complete an upgrade preflight without losing authoritative state.
- Use the primary workflow by keyboard and at desktop and mobile widths, including loading, empty, error, blocked, degraded, review, and success states.

### Completion evidence

Amp finishes with:

- A reproducible installation and seeded demonstration workspace.
- Passing Rails, Go, integration, security, and browser checks.
- Browser evidence for the primary Support and Customer Success journeys at desktop and mobile sizes.
- A dependency inventory and a record of every approved non-default production dependency.
- A tested backup and restore procedure.
- A threat model tied to implemented controls.
- A release candidate with known gaps stated plainly.

Call this state **build-complete and market-review-ready**, not validated, certified, launched, or proven in market. Those are owner judgments supported by real adoption evidence.

## 2. Product boundaries

### v1 includes

- True multi-organisation tenancy with multiple isolated workspaces per organisation.
- Email/password authentication, verification, reset, invitations, generic OIDC, and a protected local break-glass administrator.
- Owner, Admin, Manager, Member, and Viewer/Auditor roles.
- A focused native helpdesk: Accounts, Contacts, conversations, cases, assignment, status, SLA, private notes, drafts, threading, attachments, replies, and audit history.
- Shared email as the first owned channel.
- Two-way Intercom sync for conversations, Contacts, companies, assignment, tags, and notes.
- Human-only sending from NavishAI to shared email and Intercom.
- Opinionated Support and Customer Success crew templates with bounded configuration.
- Durable tasks, handoffs, evidence, runs, reviews, failures, retry, cancellation, and cost attribution.
- Admin-approved subscription CLI adapters for ChatGPT/Codex, Claude, Grok, and Cursor, plus a capability-based registry for additional runtimes.
- Read-only public-web search and guarded extraction through approved adapters.
- PostgreSQL full-text search and pgvector retrieval.
- Self-hosted Supermemory as the initial memory engine in both self-hosted and future managed NavishAI.
- Deterministic account-health signals, evidence-linked AI analysis, renewal-risk workflows, and a conversational scorecard designer.
- In-app notifications, email notifications, and configurable outbound webhooks.
- Docker Compose and native Linux as supported deployments; a cloud-neutral experimental Helm chart.
- Workspace export/import, retention controls, backup/restore, upgrade preflight, and auditable security controls.

### v1 does not include

- Autonomous, scheduled, bulk, confidence-threshold, or standing-permission customer sends.
- A customer chat widget, public help centre, social channels, campaigns, marketing automation, or a general omnichannel suite.
- Replacing every Intercom surface on day one. Intercom remains authoritative for its native conversation while NavishAI owns agent work, evidence, memory, review, and its human-send audit.
- SAML, SCIM, native mobile apps, multi-region hosting, or provider-specific infrastructure modules.
- NavishAI-managed Supermemory or silent fallback to any third-party managed memory service.
- Dodo Payments or automated managed-service billing.
- Claims of SOC 2, HIPAA, ISO 27001, or any other certification that has not been earned.
- Hidden chain-of-thought storage, unrestricted browser automation, arbitrary shell access, or general runner egress.
- A general visual agent marketplace, workflow marketplace, or unconstrained user-authored agents.

## 3. Users and operating model

The initial buyer is a founder-led or small B2B SaaS company. The product retains a credible path to mid-market controls without making the first experience enterprise-heavy. The first commercial validation is a paid private beta with about three to five design partners after self-use and an approved employer pilot.

- **Support is the wedge.** NavishAI helps a human team receive, triage, investigate, draft, review, and send high-quality responses.
- **Customer Success drives retention.** NavishAI connects cases, conversations, notes, account data, health signals, and memory to identify renewal risk and recommend interventions.

Humans remain accountable. Agents investigate, draft, analyse, organise, retrieve, recommend, and request attention. They cannot send customer messages in v1.

### Specialist crews

Support invokes only the specialists needed:

- Coordinator/Triage
- Investigator
- Resolution Drafter
- Policy/Quality Reviewer

Customer Success invokes:

- Account Analyst
- Risk Investigator
- Success Strategist
- Policy/Quality Reviewer

These are accountable roles, not a requirement to start four operating-system processes for every case. One run may execute more than one bounded step, but each visible responsibility, input, output, and review remains attributable.

Admins may edit role instructions, allowed tools, runtime profile, fallback order, budget, and review policy within safe bounds. Users cannot register arbitrary commands or bypass the approved runtime and tool registry.

## 4. Primary workflows

### Support case lifecycle

Use these states:

New -> Triaged -> Investigating -> Waiting on Customer or Waiting Internally -> Draft Ready -> Awaiting Human Review/Send -> Resolved -> Closed

A closed case can reopen on a new inbound message. Every state change records actor, source, time, reason, and preceding state.

The main path is:

1. Receive or sync a conversation and resolve its Account and Contact identity.
2. Apply deterministic priority, SLA, routing, and policy signals.
3. Invoke only the needed crew specialists.
4. Collect internal records, approved knowledge, current conversation evidence, scoped memory, and public-web evidence.
5. Produce a cited investigation and response draft.
6. Run the policy and quality review and surface conflicts, missing evidence, or stale sources.
7. Let an authenticated human inspect and edit the draft.
8. Send only when that human deliberately presses Send.
9. Attribute the send to that human and record exact content, destination, source, and result.
10. Consolidate eligible case memory at meaningful events such as correction, resolution, and closure.

An approval record must never become permission for an agent or background job to send later. Send is a fresh, human-authenticated command.

### Customer Success lifecycle

Account health uses Intercom history, shared email, NavishAI notes, and manually imported Account and Contact data through CSV or API.

1. Recalculate deterministic signals when relevant inputs change and on configured schedules or renewal windows.
2. Show every signal, value, source, time range, weight, and resulting score.
3. Start a risk investigation only for a material change or human request.
4. Let the crew add a bounded narrative, likely causes, evidence, uncertainty, and recommended interventions.
5. Keep AI output visibly separate from deterministic facts.
6. Let teams design their own scorecards by discussing outcomes and signals with an agent.
7. Convert the proposal to a deterministic, versioned definition that can be previewed and backtested before an Admin publishes it.

Cookie-cutter health models are starting templates only. Customer-specific scorecards are a core product path.

## 5. Architecture

    Browser
      |
      v
    Rails + Hotwire control plane
      - auth, tenancy, roles and policy
      - helpdesk, Customer Success and administration UI
      - jobs, notifications and integration sync
      - authoritative PostgreSQL state
      |
      | versioned authenticated runner protocol
      v
    Go execution runner
      - approved adapter and tool registry
      - process isolation, timeouts and cancellation
      - capability detection and canonical events
      - run-scoped credentials and egress policy
      |
      +--> approved subscription CLIs and model runtimes
      +--> approved public-search adapters

    Rails/PostgreSQL
      |
      +--> self-hosted Supermemory through a provider-neutral contract
      +--> SMTP/shared inbox, Intercom, object storage and webhooks

### Rails control plane

Use stable Rails and Ruby releases current at bootstrap and pin them. Prefer:

- Server-rendered ERB, Turbo, and small Stimulus controllers.
- Import maps and self-hosted assets; no Node application or JavaScript build pipeline.
- Plain product CSS with a small token and component layer.
- Rails authentication generator as the local-auth base.
- Active Job with the Rails-default database-backed queue.
- PostgreSQL-backed application, queue, and cable state unless evidence requires a change.
- Minitest and Rails system tests unless the generated native default establishes otherwise.

Rails owns business policy and durable state. It must never invoke a model CLI, arbitrary executable, or shell command directly.

### Go execution runner

Use the Go standard library first. The runner owns:

- Versioned run admission and idempotency.
- Runtime installation detection and capability reporting.
- Process start, supervision, timeout, cancellation, and reaping.
- Allowed workspaces and filesystem roots.
- Deployment-appropriate isolation and resource limits.
- Run-scoped credential delivery.
- Tool and outbound-network policy.
- Normalisation of runtime output to canonical events.
- Cost and usage observations exposed by a runtime.
- Health, readiness, and compatibility status.

Prove the protocol with a deterministic scripted adapter before enabling a live runtime. The scripted adapter is a test and demonstration tool, not the product milestone.

### PostgreSQL authority

PostgreSQL is authoritative for tenant, business, security, policy, and execution-ledger state:

- Organisations, workspaces, users, roles, invitations, and sessions.
- Accounts, Contacts, identities, conversations, cases, messages, attachments, notes, tags, and SLA state.
- Crew templates, agent profiles, tasks, handoffs, runs, events, evidence, reviews, drafts, and sends.
- Runtime approvals, tool policies, budgets, routing decisions, and audit events.
- Knowledge sources and version metadata.
- Scorecards, signals, health evaluations, interventions, and outcomes.
- Memory records, source references, scope, retention, correction, supersession, and deletion state.

Supermemory indexes and retrieves eligible memory. It is not the source of truth for cases, messages, policy, approvals, or audit.

### Domain invariants

- Agent identity is separate from runtime adapter, provider account, model, task, run, session, or event.
- Provider conversations are optional continuity, never authoritative business state.
- Durable tasks, evidence, reviews, and decisions are the work record; hidden agent chat is not.
- Every tenant-owned row is scoped and authorised through the active workspace.
- Cross-workspace memory, search, retrieval, and execution are denied by default.
- Retry and fallback cannot duplicate a send, source write, task completion, or chargeable execution.
- Current authoritative knowledge overrides stale memory or model output.
- Customer messages are sent only by a contemporaneous authenticated human command.

## 6. Runtime and public-web policy

### Runtime registry

Support ChatGPT/Codex subscription, Claude eligible subscription or team seat, Grok through the approved X/ACP path, and Cursor subscription/ACP in v1. Allow many more adapters without provider-specific fields in core domain tables.

Each approved installation records:

- Adapter key and protocol version.
- Resolved executable path and version.
- Non-secret authenticated-account metadata.
- Declared capabilities and compatibility status.
- Allowed workspaces, roles, tools, data classes, and budgets.
- Health, last check, and known incompatibility reason.

Subscription credentials stay on the customer-controlled runner. NavishAI detects and invokes an authenticated CLI but does not import, copy, display, or store its login token.

Runtime selection is a workspace default with optional per-agent override and an ordered fallback profile. Fallback is allowed only when capability, data policy, workspace, approval, and task semantics remain compatible. Record the selected runtime and fallback reason.

Detect versions against maintained compatibility ranges. Warn or block known-incompatible versions. Never auto-upgrade a customer's CLI or infrastructure.

### Public-web search

Agents may autonomously perform read-only public-web search because current public information is routine Support and Customer Success evidence. This does not grant unrestricted runner egress.

Expose a typed web_search tool through a provider-neutral registry:

- Prefer a runtime's native search when it returns auditable structured results and satisfies workspace policy.
- Also support approved HTTP adapters such as self-hosted SearXNG, Exa, Tavily, and Parallel.
- Normalise query, provider, URLs, excerpts, publication and retrieval dates, citations, policy decision, and observed cost.
- Send the minimum query and context needed and redact prohibited secrets or personal data.

Treat web_extract as a separate guarded capability. Prefer provider-hosted extraction. A NavishAI fetcher must block loopback, private, link-local, metadata, cluster, and reserved addresses; revalidate DNS and redirects; limit time, size, and MIME type; strip active content; and send no ambient cookies or credentials.

Web content is untrusted evidence, never instructions. It does not enter durable memory automatically. Interactive browser control, authenticated browsing, and internal-network browsing are separate future capabilities.

Classify and minimise data before execution. Runtime and tool policy determines which data classes an adapter can receive. The UI shows the selected runtime, material data categories disclosed, evidence returned, and policy or fallback reason without copying sensitive prompts into broad logs.

## 7. Memory and retrieval

Memory is a core capability, not a later experiment.

Use a provider-neutral internal memory contract with self-hosted Supermemory as the first implementation for both self-hosted and future managed NavishAI. Do not depend on Supermemory's managed service. Preserve the ability to replace, fork, or add an engine.

Support four typed classes:

- **Episodic:** case events, decisions, corrections, outcomes, and time-bound interactions.
- **Semantic:** durable facts about Accounts, Contacts, products, and recurring issues.
- **Profile:** preferences, constraints, relationships, and working context.
- **Procedural:** approved playbooks, policies, and ways of working.

Every memory has a source, observed and valid times, scope, confidence, retention rule, and supersession state. Use explicit scopes for organisation, workspace, Account, Contact, case, crew, agent, and user, with controlled inheritance.

Current source records outrank inference. An authorised human correction has the highest priority. Preserve conflicting history through supersession rather than silently overwriting it.

Capture episodic records continuously. Agents may propose durable facts and preferences. An authorised human publishes procedural or policy memory. Consolidate at case closure, review, correction, outcome, and scheduled curation points.

Context assembly uses a fixed budget, scope and relevance ranking, separates memory from current evidence, and cites every retrieved item. Do not store hidden chain of thought.

Admins and Managers can inspect scoped memories. Members can inspect memories used in their work. Authorised users can propose corrections. Audit access to sensitive memory.

### Degraded mode

If Supermemory is unavailable:

- Preserve authoritative writes and deterministic workflows.
- Stop memory capture and recall explicitly rather than pretending they succeeded.
- Warn users and operators.
- Queue safe, idempotent indexing retries.
- Block only a workflow explicitly marked memory-critical.
- Never fall back to a managed memory provider.

Provide complete workspace-scoped export/import in documented formats. PostgreSQL facts and source references must be sufficient to reconstruct the external index.

## 8. Helpdesk, identity, knowledge, and integrations

### Accounts and Contacts

Represent source identities under NavishAI Accounts and Contacts. Match only on deterministic safe keys. Send ambiguous matches to review. Merges and unmerges are audited and recoverable.

### Shared email

Receive mail through inbound forwarding or webhook and support ordinary SMTP. Preserve threading identifiers and original source data. SMTP sends occur only after an authenticated human presses Send.

### Intercom

Sync conversations, Contacts, companies, assignment, tags, and notes through webhooks plus reconciliation. Intercom remains authoritative for the native Intercom conversation. NavishAI is authoritative for its crew work, evidence, memory, review, and human-send audit.

Customer-facing Intercom writes require a fresh authenticated human action. Background agents and jobs cannot send on the user's behalf.

### Attachments

Support inbound and outbound attachments with configured limits, content sniffing, quarantine, malware scanning, authorised download, and local or S3-compatible storage. Never trust extension or browser-provided MIME type alone.

### Knowledge

Approved v1 sources are public URLs, uploaded documents, manually maintained knowledge, and Intercom Help Center. Track source, version, retrieval or sync time, expiry, and deletion. Warn on stale or deleted material. Current authoritative content beats memory.

GitHub repositories, private runbooks, and broad connector ingestion come later.

## 9. Security, privacy, and enterprise readiness

Design for evidence useful to SOC 2, HIPAA-aligned deployments, ISO-style controls, and enterprise security questionnaires. Never claim certification or compliance that has not been independently established.

Required posture:

- Deny-by-default workspace authorisation in controllers, jobs, channels, search, memory, integrations, and runner requests.
- Encrypt application secrets; keep subscription CLI credentials on the runner; deliver only scoped just-in-time execution material.
- Audit authentication, role, policy, runtime, data disclosure, memory, integration, human-send, export, retention, and administrator actions without logging secret values.
- Tenant-configurable content retention, separate append-only security and approval audit retention, export and deletion workflows, and tombstones where a retained audit record cannot be erased.
- No outbound telemetry in self-hosted installations by default. Use local metrics and logs; any future anonymous telemetry is opt-in.
- Signed and protected webhooks, replay prevention, idempotency, bounded retries, and dead-letter visibility.
- CSRF, session fixation, rate-limit, open-redirect, SSRF, injection, unsafe rendering, attachment, and privilege-escalation coverage.
- A threat model covering browser, Rails, queue, PostgreSQL, runner, CLI processes, search and extraction, Supermemory, email, Intercom, object storage, and updates.
- Dependency pinning, lockfiles, provenance review, automated vulnerability checks, an SBOM for releases, and a documented patch policy.

Deployment isolation:

- Compose: a dedicated runner container with no Docker socket.
- Native Linux: a dedicated service account and process boundary.
- Experimental Helm: separate runner Jobs or equivalent workload isolation.
- Every mode: allowed roots, resource bounds, timeouts, cancellation, scoped credentials, and explicit egress policy.

## 10. UX requirements

NavishAI should feel like a calm operating workspace, not a dashboard of bots or a generic admin template.

Primary surfaces:

- Inbox and case queue.
- Case workspace with conversation, facts, crew progress, evidence, memory, review, and draft.
- Accounts and Contacts.
- Account health and renewal-risk workspace.
- Scorecard designer and version history.
- Knowledge and memory inspection.
- Crew, runtime, search, integration, security, retention, and workspace administration.
- Audit and operational health.

Use progressive disclosure. A human should see the current decision, source, uncertainty, blocking issue, and next action without reading raw model traces.

Every meaningful surface covers loading, empty, partial, stale, degraded, permission-denied, validation, integration-failure, runtime-failure, blocked, review, and success states. Support keyboard navigation, visible focus, semantic HTML, screen readers, reduced motion, responsive layouts, and safe text wrapping.

For meaningful UI work in Amp, use Impeccable and Ui.sh and only relevant Matt Pocock skills. These are quality tools, not permission to introduce React, TypeScript, Vite, npm, or an unapproved dependency tree.

## 11. Autonomous implementation protocol

The roughly 40 PRs below are checkpoints, not 40 owner meetings. Amp keeps moving while the preceding PR is green.

For every PR:

1. State objective, done checks, constraints, and non-goals in the PR description.
2. Base it on the preceding PR and keep it independently understandable and reversible.
3. Use atomic Conventional Commits.
4. Run native format, lint, focused tests, and relevant broader checks.
5. Inspect meaningful UI changes at desktop and mobile sizes.
6. Update this brief only when a durable decision or ordering changes.
7. Push the green checkpoint and immediately begin the next PR.

Amp may make low-risk implementation choices inside the settled architecture. It stops only when:

- A new production dependency or external service is necessary and not already approved.
- A missing credential, paid account, or external administrative action blocks useful local progress.
- Two settled decisions conflict in a way that changes security, scope, data handling, licensing, or cost.
- The next action is destructive, irreversible, force-pushes history, or unexpectedly changes a real external system.
- Evidence shows the planned architecture cannot meet a required outcome.

When blocked, batch related choices into one concise request with evidence and a recommendation. Continue every independent safe slice first.

### Planned PR stack

#### Phase A — secure foundation

1. **Repository bootstrap:** pinned Rails/PostgreSQL/Hotwire and Go skeletons, local setup, native checks, CI, and dependency baseline. Evidence: clean setup and tests from a fresh checkout.
2. **Organisation and workspace tenancy:** organisations, isolated workspaces, memberships, and tenant-scoped access primitives. Evidence: cross-workspace tests fail closed.
3. **Authentication and roles:** local auth, verification, reset, invitation, first-owner bootstrap, role enforcement, and break-glass flow. Evidence: role-matrix system tests.
4. **Application shell and design language:** accessible navigation, responsive shell, tokens, components, forms, flashes, and standard states. Evidence: desktop, mobile, and keyboard browser checks.
5. **Audit and security baseline:** append-only audit events, actor/source metadata, secure headers, filtered parameters, rate-limit primitives, and threat-model skeleton. Evidence: focused security tests and no secrets in logs.

#### Phase B — focused native helpdesk

6. **Accounts, Contacts, and source identities:** deterministic matching, ambiguity review, and recoverable merge/unmerge. Evidence: identity and isolation tests.
7. **Conversations, messages, and cases:** threading, lifecycle, assignment, tags, notes, priority, and reopen behaviour. Evidence: state and authorisation tests.
8. **Inbox and case workspace UX:** queue filters, case layout, history, responsive conversation view, and all basic states. Evidence: desktop and mobile browser journeys.
9. **SLA engine:** calendars, holidays, first-response and resolution targets, pause rules, warnings, and escalation tasks. Evidence: boundary-time deterministic tests.
10. **Shared-email intake:** forwarding/webhook ingestion, SMTP configuration, threading, duplicate suppression, and failure visibility. Evidence: fixture receive and reconciliation tests.
11. **Human-only email send:** editable draft, fresh Send command, exact attribution, idempotency, attachment checks, and delivery state. Evidence: agents and jobs cannot send; retry cannot duplicate.
12. **Attachments and object storage:** bounded transfer, sniffing, quarantine, malware-scan contract, local/S3 backends, and authorisation. Evidence: malicious and cross-tenant fixtures fail closed.
13. **Knowledge sources:** manual content, URL and upload ingestion, Intercom Help Center contract, versions, freshness, expiry, full-text search, and citations. Evidence: stale and deleted source behaviour.

#### Phase C — durable agent work

14. **Crew and agent configuration:** opinionated Support and CS templates, bounded roles, instructions, tools, runtime profiles, budgets, and policy. Evidence: non-admins cannot expand authority.
15. **Tasks and handoffs:** durable assignments, dependencies, comments, evidence, review requests, outcomes, and crew progress. Evidence: refresh and retry preserve state.
16. **Versioned runner protocol:** authenticated Rails client, Go admission API, canonical requests/events, health, and idempotency. Evidence: contract tests on both sides.
17. **Deterministic scripted adapter:** fixtures for success, retry, timeout, cancellation, malformed output, and policy denial. Evidence: reproducible end-to-end runs without a model.
18. **Run ledger and event ingestion:** durable ordered events, replay, attempts, fencing where needed, usage observations, and terminal-state rules. Evidence: duplicate and out-of-order tests.
19. **Execution supervision:** process bounds, allowed roots, timeout, confirmed cancellation, reaping, scoped credentials, and egress policy. Evidence: runner boundary tests.
20. **Investigation, drafting, and quality review:** cited outputs, change requests, reruns, draft versions, conflicts, and uncertainty. Evidence: full scripted Support Crew journey.
21. **Execution UX and recovery:** live progress, blocked/degraded/failure states, cancel/retry, reconciliation, and operator diagnostics. Evidence: browser and failure-injection tests.

#### Phase D — live runtimes and safe research

22. **Runtime approval registry:** detection, path/version, account metadata, capabilities, workspace policy, compatibility ranges, and Admin UI. Evidence: unapproved executables cannot run.
23. **ChatGPT/Codex subscription adapter:** capability-detected invocation and canonical output without importing credentials. Evidence: mocked contract plus opt-in live smoke test.
24. **Claude subscription adapter:** the same security and protocol guarantees. Evidence: mocked contract plus optional live smoke test.
25. **Grok ACP subscription adapter:** the same security and protocol guarantees. Evidence: mocked contract plus optional live smoke test.
26. **Cursor ACP subscription adapter:** the same security and protocol guarantees. Evidence: mocked contract plus optional live smoke test.
27. **Routing, fallback, and budgets:** workspace default, agent override, compatible fallback, budgets, disclosure, usage, and hard stops. Evidence: incompatible fallback is denied and reasons are visible.
28. **Public-web search:** typed native/provider adapters, normalised citations, policy, redaction, cost, and review UX. Evidence: provider fixtures and citation rendering.
29. **Guarded extraction:** SSRF-safe retrieval, DNS and redirect revalidation, limits, sanitisation, and prompt-injection boundary. Evidence: hostile-endpoint suite.

#### Phase E — core memory

30. **Memory contract and schema:** types, scopes, provenance, time, confidence, retention, supersession, and engine interface. Evidence: scope and conflict tests.
31. **Self-hosted Supermemory integration:** health, indexing, retrieval, tenant isolation, and local deployment. Evidence: contract and cross-tenant denial tests.
32. **Capture and consolidation:** episodic capture, proposed facts/preferences, authorised procedural publication, outcomes, and idempotent indexing. Evidence: case-to-closure tests.
33. **Context and explainability:** fixed budgets, relevance, source separation, citations, disclosure, and no chain-of-thought persistence. Evidence: deterministic selection tests.
34. **Inspection and correction:** scoped UI, sensitive-access audit, correction, supersession, retention, deletion, and tombstones. Evidence: role and audit browser tests.
35. **Degraded mode and portability:** explicit outage behaviour, retry, index reconstruction, complete export/import, and engine seam. Evidence: Supermemory-offline journey.

#### Phase F — Intercom and Customer Success

36. **Intercom identity and two-way sync:** Contacts, companies, conversations, assignment, tags, notes, webhooks, reconciliation, and source ownership. Evidence: replay and drift tests.
37. **Human-only Intercom send:** editable draft, fresh authenticated Send, human attribution, failure/retry, and no agent entry point. Evidence: privilege and duplicate-send tests.
38. **Account health and renewal risk:** imports/API, deterministic signals, material-change evaluation, renewal windows, crew analysis, evidence, uncertainty, and interventions. Evidence: typed calculations and full risk journey.
39. **Conversational scorecard designer:** proposal, signal mapping, preview, backtest, explanation, Admin publish, versioning, and rollback. Evidence: published scores are deterministic and reversible.

#### Phase G — operational release candidate

40. **Operations and release hardening:** generic OIDC, notifications/webhooks, retention/export, Compose/native Linux, experimental Helm, backup and verified restore, upgrade preflight, SBOM/provenance, security review, accessibility and responsive polish, seeded demo, and release documentation.

PR 40 is an outcome group, not permission for a giant diff. Split it into additional atomic stacked PRs when reviewability requires it. Expect about **38-45 PRs** for the full scope. The number is an estimate; atomicity and evidence are the constraints.

## 12. Deployment and operations

Support:

- **Docker Compose:** Rails, jobs, PostgreSQL, runner, Supermemory, and optional object storage/search services.
- **Native Linux:** supported packages and services with a dedicated runner user.
- **Helm:** experimental and cloud-neutral until it reaches the same upgrade, backup, and security evidence.

Do not ship provider-specific Terraform modules in v1. Publish inputs and cloud-neutral Helm resources that customers can compose into existing Terraform estates.

Backups cover PostgreSQL, object storage, configuration and secret references, and Supermemory state or deterministic index reconstruction. Provide coordinated backup, verification, restore, and restore-test instructions.

Releases use pinned artifacts, checksums, signatures where supported, migration preflight, backups, compatibility checks, upgrade tests, and explicit rollback boundaries. Never silently upgrade a CLI, database, memory service, or infrastructure component.

## 13. Licensing and commercial path

The intended model is an open-source NavishAI licence with a commercial option:

- Individuals and for-profit organisations may self-host, use internally, and modify NavishAI.
- The licence restricts offering NavishAI as a competing hosted or managed service without a commercial agreement.
- NavishAI will describe the product as open source while disclosing that restriction plainly and not implying OSI approval.
- Final licence text and contributor terms require legal review before the first public release.

The self-hosted product has full capabilities. A future managed offering sells operation, hosting, upgrades, backups, support, and reduced maintenance, not an artificially uncrippled edition.

Billing stays manual until demand is validated. Dodo Payments is the intended later billing integration.

## 14. Interview decision ledger

This table captures the final answer to every numbered product question. Later clarifications supersede provisional answers.

| Q | Final decision |
|---:|---|
| 1 | Start with founder-led and small B2B SaaS teams; retain a mid-market path. |
| 2 | Validate through a paid private beta with about three to five design partners. |
| 3 | Build Support and Customer Success, matching the owner's expertise and route to market. |
| 4 | Enter beside the incumbent helpdesk; NavishAI owns agent work, evidence, memory, review, and human-send audit, with a path to deeper replacement. |
| 5 | Launch self-hosted open source first; offer managed hosting later. |
| 6 | Agents assist, investigate, draft, and recommend; humans retain consequential authority. Q62-Q64 define sending. |
| 7 | Provide opinionated crew templates with bounded configuration. |
| 8 | Self-hosted has full capability; managed sells operations and support. |
| 9 | The first CS workflow is Account Health and Renewal Risk intervention. |
| 10 | Integrate Intercom and a shared email inbox first. |
| 11 | Optimise deployment for operator UX; Q73 records the final support tiers. |
| 12 | Support API keys/local endpoints and authenticated subscription CLIs, especially ChatGPT/Codex, Claude, Grok, and Cursor. |
| 13 | Use email/password, verification, reset, invitations, and self-hosted first-Owner bootstrap. |
| 14 | Keep billing manual initially; add Dodo Payments after managed demand is validated. |
| 15 | Build readiness evidence for SOC 2, HIPAA-aligned deployments, ISO-style programmes, and enterprise reviews; claim nothing unearned. |
| 16 | Retain a Helm path that fits enterprise Terraform-managed estates. |
| 17 | The early AGPL idea was superseded by Q30-Q31. |
| 18 | Keep subscription credentials on the customer runner; never import or store CLI login tokens. |
| 19 | Account risk uses Intercom, shared email, NavishAI notes, and manually imported Account and Contact data through CSV or API. |
| 20 | Shared email is the first owned channel alongside Intercom. |
| 21 | Admins approve allowed CLIs and scope; non-admins cannot configure arbitrary runtimes. |
| 22 | Validate with synthetic or redacted data, then an approved self-hosted employer pilot. |
| 23 | Superseded by Q73: Compose and native Linux supported, Helm experimental. |
| 24 | Ship the four required adapters and a registry for many more; do not shape the domain around providers. |
| 25 | Admins approve detected adapter, path, version, account metadata, capabilities, and workspaces; never arbitrary commands. |
| 26 | v1 contains a focused native helpdesk with Contacts, conversations, assignment, status, SLA, notes, drafts, threading, and replies. |
| 27 | Intercom sync is two-way for core records using webhooks plus reconciliation; ownership boundaries stay explicit. |
| 28 | Initial knowledge sources are approved URLs, uploads, maintained content, and Intercom Help Center. |
| 29 | Health combines deterministic visible signals with bounded AI narrative and recommendations, then customer-designed scorecards. |
| 30 | Use a NavishAI source licence: internal commercial use and modification are allowed; a competing hosted service needs a commercial licence. |
| 31 | Call NavishAI open source, disclose the hosted-service restriction, and make no claim of OSI approval. |
| 32 | Do not ship provider-specific Terraform; keep Helm cloud-neutral and composable. |
| 33 | Use a workspace runtime default, optional per-agent override, and ordered compatible fallback profiles, all Admin-approved. |
| 34 | Use deployment-native runner isolation plus common roots, resources, timeouts, credentials, and egress controls. |
| 35 | Include a conversational scorecard designer producing deterministic, versioned, previewable, backtestable definitions with rollback. |
| 36 | Shared email is the only first-party communication channel in v1; no widget, social, or marketing suite. |
| 37 | Use PostgreSQL full-text plus pgvector retrieval from the start. |
| 38 | Supermemory was considered for memory; Q39 makes it the selected first implementation. |
| 39 | Use self-hosted Supermemory for both self-hosted and future managed NavishAI; never its managed service. |
| 40 | Store provenance-linked facts, decisions, preferences, summaries, and outcomes with scope, retention, correction, and deletion; no hidden chain of thought. |
| 41 | Implement true multi-organisation tenancy with multiple isolated workspaces. |
| 42 | Fallback only when capability, data policy, workspace, approval, and semantics are compatible; record the reason. |
| 43 | Detect CLI versions, maintain compatibility ranges, and warn or block known incompatibilities; never auto-upgrade. |
| 44 | Roles are Owner, Admin, Manager, Member, and Viewer/Auditor. |
| 45 | Resolve source identities under Accounts and Contacts with deterministic matching, ambiguity review, and audited merge/unmerge. |
| 46 | Support attachments with limits, sniffing, quarantine, malware scanning, authorised access, and local/S3-compatible storage. |
| 47 | Provide local auth, generic OIDC, and a protected break-glass Admin; SAML and SCIM come later. |
| 48 | Make content retention tenant-configurable; retain security and approval audit separately with export, deletion workflows, and tombstones. |
| 49 | PostgreSQL stores authoritative records; Supermemory profiles, indexes, associates, and retrieves eligible memory. |
| 50 | Memory types are episodic, semantic, profile, and procedural. |
| 51 | Capture episodic memory automatically; agents propose durable facts and preferences; authorised humans publish procedural and policy memory. |
| 52 | Scope memory to organisation, workspace, Account, Contact, case, crew, agent, and user with controlled inheritance. |
| 53 | Track source, observed and valid time, confidence, and supersession; source beats inference and authorised correction ranks highest. |
| 54 | Assemble context to a fixed budget by scope and relevance; separate memory from evidence and cite it. |
| 55 | Capture events continuously and consolidate at closure, review, correction, outcome, and scheduled curation. |
| 56 | On memory outage, use explicit degraded mode, preserve core work, stop false recall and capture, warn, and retry safely; never use managed fallback. |
| 57 | Provide complete workspace-scoped export and import in documented formats. |
| 58 | Admins and Managers inspect scoped memory, Members inspect memory used in work, authorised users propose corrections, and sensitive access is audited. |
| 59 | Invoke only the Support or CS specialists needed; roles remain accountable when execution is consolidated. |
| 60 | Use the explicit support lifecycle from New through Closed with waiting, draft, human review/send, and reopen states. |
| 61 | Recalculate health on input changes and schedules; invoke agent investigation for material changes or human requests. |
| 62 | Agents never send, schedule, or trigger customer messages in v1. |
| 63 | A human reviews and edits a draft and deliberately presses Send in NavishAI; attribute it to that human. |
| 64 | Intercom and email writes occur only from that fresh human action; approval never hands sending back to an agent. |
| 65 | Track knowledge source, version, freshness, expiry, and deletion; current authoritative material beats memory. |
| 66 | Notify through in-app, email, and configurable outbound webhooks for assignments, review/send, SLA, failures, blocked work, and completion. |
| 67 | Encrypt app secrets, keep CLI credentials on the runner, use scoped just-in-time material, and audit without values. |
| 68 | Give agents safe read-only public-web search through native or approved adapters and guarded extraction, while treating web as untrusted evidence and denying general egress. |
| 69 | Classify, minimise, redact, and policy-check sensitive data; disclose which runtime receives which categories without overlogging prompts. |
| 70 | Self-hosted sends no telemetry by default; use local metrics/logs and make future anonymous telemetry opt-in. |
| 71 | Coordinate backup, verification, restore, and reconstruction across PostgreSQL, object storage, configuration, and memory. |
| 72 | Use pinned releases, checksums and signatures where possible, migration preflight, backup, compatibility and upgrade tests, and explicit rollback boundaries. |
| 73 | Support Docker Compose and native Linux; ship Helm as experimental; do not ship provider-specific Terraform modules. |
| 74 | Amp may finish at fully implemented, checked, owner-review-ready v1 without waiting for a mandatory live pilot; launch remains the owner's decision. |

There was no distinct Q75 decision. The Q59-Q75 reference was a range shorthand; the interview ended at Q74.

## 15. Owner working preferences

- Treat the owner as hands-on. Delegate effort, not judgment or accountability.
- Lead with outcomes and current evidence. Distinguish planned, built, tested, merged, released, deployed, and verified.
- Freeze objective, done checks, non-goals, and constraints before substantial work.
- Make safe, reversible assumptions and continue. Ask only when scope, risk, cost, data handling, or result changes materially.
- Prefer the smallest complete solution and framework-native capabilities.
- Do not add a production dependency without approval and a stated security and maintenance cost.
- Preserve user-owned work and keep unrelated changes out of commits.
- Use atomic Conventional Commits and green stacked PRs.
- Do not make the owner approve or initiate each PR in an autonomous build.
- Run native checks and visually inspect meaningful UI work on desktop and mobile.
- Keep documentation lean, remove stale text, and do not create parallel plans.
- Keep updates short: what changed, what failed, and what comes next.

AGENTS.md is the short operational version of these preferences. This file is the product and implementation authority.
