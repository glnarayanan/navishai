# Threat model

This baseline records NavishAI's main assets, trust boundaries, threats, and current controls. Update it when a new data path, runtime, integration, or authority enters the product.

## Assets

- Workspace identity, membership, role, policy, and customer-operation data
- User sessions, password and invitation tokens, application secrets, and integration credentials
- Agent tasks, evidence, drafts, memory, runtime approvals, and execution records
- Append-only security, approval, and human-action audit events

## Trust boundaries

```text
┌─────────┐   HTTPS   ┌───────────────┐   SQL   ┌────────────┐
│ Browser │──────────▶│ Rails control │────────▶│ PostgreSQL │
└─────────┘           │ plane         │         └────────────┘
                      │               │ bounded memory API
┌───────────────┐     │               ▼
│ Email/Intercom│────▶│       ┌────────────────┐
└───────────────┘     │       │ Self-hosted   │
 signed webhooks      │       │ memory index  │
                      │       └────────────────┘
                      └───────┬───────┘
                              │ versioned protocol
                              ▼
                      ┌───────────────┐
                      │ Go runner     │
                      └───────┬───────┘
                              │
                  ┌───────────┴───────────┐
                  │ approved adapter      │ bounded search
                  ▼                       ▼
          ┌───────────────┐       ┌───────────────┐
          │ Agent runtime │       │ Search service│
          └───────────────┘       └───────────────┘
```

Browser input, mail and integration payloads, public web content, model output, runtime output, uploads, and retrieved memory are untrusted. Rails owns user and workspace authority. PostgreSQL owns durable business, policy, security, and audit state. Only the Go runner may start an agent runtime or arbitrary process.

## Baseline threats and controls

| Threat | Required control |
|---|---|
| Cross-workspace access or insecure object reference | Resolve records through the current user's membership and current workspace; fail closed; test another tenant's identifiers. |
| Credential guessing and account discovery | Generic failures, constant-work password checks, shared IP rate limits, short-lived signed tokens, and filtered logs. |
| Session theft, replay, or stale authority | Signed secure HTTP-only cookies, fixed expiry, server-side revocation, row-locked credential changes, and role revalidation. |
| Cross-site request, script, framing, or content injection | Rails CSRF protection, strict content security policy, frame denial, same-origin browser isolation, output escaping, and no runtime CDN. |
| Secret or personal-data disclosure through logs and audit | Parameter filtering plus structured audit metadata that rejects credential-like keys and has a strict size bound. |
| Audit tampering or ambiguous attribution | PostgreSQL rejects updates and deletes; events record actor kind, source, request, network address, subject, workspace, and stable action names. Direct database administration remains a privileged trust boundary. |
| Source identity poisoning or cross-workspace merge | Match only exact normalized email or domain keys inside one workspace; block conflicting roots for Manager-or-higher review; preserve source identity, candidate, and merge history. |
| Forged, cross-tenant, or rewritten Account health input | Require a current Manager-or-higher Workspace membership for CSV and authenticated API imports; bound rows and bytes; accept only typed allowlisted fields; bind supplier and Account through composite foreign keys; keep source IDs idempotent and snapshots append-only. |
| Opaque or manipulated renewal-risk score | Calculate only from retained typed inputs and Workspace-scoped PostgreSQL facts; freeze every value, source, range, weight, and risk contribution; serialize Account calculation; expose stable signal citations and prior snapshots. Keep AI narrative outside the score. |
| Unreviewed or rewritten scorecard changes future risk | Map only allowlisted retained signals to bounded deterministic weights and health bands. Keep proposals and backtests append-only, require a backtest before publish, limit publish and rollback to current Owners and Admins, bind every record through Workspace foreign keys, and record the version on each assessment. |
| Risk analysis overstates evidence or contacts a customer | Start Crew analysis only for a material change, renewal window, or human request. Require Workspace-checked citations and explicit uncertainty. Treat interventions as human-owned proposals; expose no send tool or background send path. |
| Duplicate or reordered security actions | Database uniqueness, row locks, signed token state, idempotency keys where a protocol crosses processes, and transactional state-plus-audit writes. |
| Compromised model, tool, or runtime | Rails never starts runtimes; the runner admits only approved versioned requests and must enforce roots, time, process, credential, and egress bounds. |
| Runtime egress escape or profile substitution | Deny sockets and io_uring by default. Bind each network profile to one canonical approved executable and an owner-checked subordinate user/network namespace pair. The launcher clears capabilities before execution; Seccomp blocks namespace and mount changes for the full process tree. Deployment must enforce destination policy inside the namespace. |
| Agent authority expansion through configuration | Fixed specialist roles cap allowed tools; runtime profiles come from an approved provider-neutral registry; budgets have hard bounds; profile changes are immutable, tenant-scoped, and limited to Owners and Admins. Customer send is not an agent tool. |
| Unsafe external fetch or webhook | Authenticate webhooks; revalidate DNS and redirects; bound size and time; treat content as evidence, not instruction. These controls arrive with each integration. |
| Public search leaks customer data or imports hostile instructions | Rails removes common email, phone, and secret patterns before disclosure; role policy gates the tool. The signed runner endpoint uses an approved provider, bounded requests and responses, no redirects, HTTPS-only result links, normalized fields, durable idempotency, and cost records. Rails stores and displays results as untrusted evidence and validates each citation against the task that obtained it. |
| Knowledge or public-result URL SSRF, DNS rebinding, active HTML, or prompt injection | Fetch only an approved source or immutable result HTTPS URL without credentials; reject every private or reserved DNS answer; pin the checked address while retaining TLS hostname checks; revalidate redirects; bound time and bytes; discard active markup; store an immutable digest; label bounded text as untrusted evidence; never add it to memory automatically. |
| Managed-memory fallback, cross-workspace recall, or poisoned index results | Use only the configured self-hosted engine; reject managed hosts and cleartext remote links. Derive a Workspace container and Organisation/Workspace metadata from PostgreSQL, apply both as search filters, reject every result whose returned scope or tenant metadata differs, and load authoritative content by its Workspace-owned PostgreSQL key. |
| Agent memory poisoning or duplicate indexing | Keep agent facts and preferences as immutable proposals until Manager-or-higher review; permit procedural publication only from that same human authority boundary. Capture source events transactionally, retain source digests, and use one stable PostgreSQL Memory key as the idempotent external document ID. |
| Memory prompt injection, stale recall, or false citation | Retrieve only current, indexed, time-eligible PostgreSQL records within inherited task scopes. Bound records and total context, separate corrections, source facts, and inferences, mark memory as context rather than instruction, and give current sources and approved knowledge precedence. Freeze each selection against the run and accept a `memory://` citation only from that run. Do not persist hidden chain of thought. |
| Sensitive Memory browsing or unauthorised correction | Let Managers, Admins, and Owners inspect Workspace Memory; let Members inspect only records selected for their owned task runs; deny Viewers. Audit each library and record view without copying content. Require Manager-or-higher authority to publish or review a correction, preserve proposals and superseded records, and bind actor tuples to the Workspace in PostgreSQL. |
| Deleted Memory recalled or left in the external index | Create an append-only tombstone under a locked record, exclude it from PostgreSQL retrieval at once, and keep a durable external-removal state with safe retry. Lock and recheck each selected record before run creation so deletion, correction, expiry, and index-state changes cannot race into a new run. |
| Memory outage causes false recall, write loss, retry storms, or managed fallback | Continue source transactions and PostgreSQL Memory capture, return no recalled Memory, freeze and show the degraded run state, and disclose no Memory data class. Leave later indexing pending after a failed or unknown attempt, then use explicit stable-key reconstruction. Never call a managed fallback. |
| Memory archive crosses tenants or imports partial data | Bind an archive to one Workspace key, require an empty target with matching referenced records, bound input to 20 MiB, validate every row and supersession link, and import in one transaction. Exclude engine-private IDs, rebuild the index from PostgreSQL, and audit export, import, and reconstruction without content. |
| Retained customer content outlives policy or survives in external stores | Run tenant-scoped expiry under one database advisory lock. Delete attachment objects and external Memory entries first; stop and show a failed run on any uncertain cleanup. A fixed database function then locks its target tables and replaces expired plaintext and source identifiers while preserving structural ledgers and the separately retained audit trail. Only Owners can request an extra run. |
| Forged, replayed, or oversized inbound email | Use a per-inbox unguessable endpoint plus a deployment-held HMAC secret, reject stale timestamps and oversized bodies before parsing, suppress duplicate Message-IDs, retain a source digest, and render extracted body text without trusted HTML. |
| Forged, replayed, cross-app, or drifting Intercom data | Use an unguessable connection endpoint and exact-body HMAC check, cap input before parsing, require the configured app ID, deduplicate by notification ID and digest, retain durable attempts, and reconcile cursor-paged remote state. Bind every mapping through composite Workspace foreign keys. Keep remote state and assignment distinct, and remove only connection-owned tags and identity keys. |
| Duplicate or unattributed Intercom write | Freeze each local note, assignment, tag, and untag operation with its current human Membership and User tuple. Match Intercom admins by exact email, claim once before external I/O, retry only definite failures with a cap, and stop an interrupted or uncertain result for review. Never put a customer reply in this operation set. |
| Duplicate, stale, or unattributed Intercom customer reply | Bind every form to the newest synced conversation part. Recheck a current authenticated writer and matching Intercom admin, then freeze the body, source part, remote conversation, and human actor before one external call. Definite rejection needs a fresh command. Uncertain results block resend until a writer verifies the exact remote part or marks it not sent. Serialize reply completion with sync for that conversation. |
| Unauthorised customer communication | No agent, job, approval, or background trigger receives send authority. A current authenticated human must review and issue each send command. |
| Webhook replay, content leak, or server-side request forgery | Send only fixed content-free alert fields with a stable event ID; HMAC-sign the exact body; require public HTTPS; reject credentials, local names, private or mixed DNS answers, and redirects; pin the checked address for TLS. |

## Review rules

- Add an event and a denial test when a change adds authority, sensitive disclosure, or an external side effect.
- Never store passwords, tokens, secret values, raw credentials, or unrestricted request parameters in audit metadata.
- Mark planned controls as planned until executable tests prove them.
- Treat database, deployment host, backup, and operator access as privileged. Release hardening must document key handling, backup access, restore checks, and incident response.
