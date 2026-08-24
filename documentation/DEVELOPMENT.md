# Development

NavishAI uses Ruby 3.4.10, Rails 8.1.3.1, PostgreSQL 15 with pgvector 0.8.6, and Go 1.27.0.

## First setup

Install the pinned Ruby and Go versions, PostgreSQL 15, and pgvector 0.8.6. Create `navishai_development` and `navishai_test`, then run:

```sh
bin/setup --skip-server
```

The Amp orb setup script installs these system tools and prepares both databases.

## First Owner and recovery access

Set `NAVISHAI_BOOTSTRAP_TOKEN` to a random value of at least 32 bytes before the first start. Open `/setup/new` from the deployment host and enter that token to create the first organisation, workspace, and Owner. Setup closes for good after it succeeds.

Create or reset the one local break-glass Admin with:

```sh
ORGANIZATION_SLUG=acme WORKSPACE_SLUG=support EMAIL=recovery@example.com PASSWORD='a-long-random-password' bin/rails navishai:break_glass:create
```

Set `NAVISHAI_BREAK_GLASS_TOKEN` to a separate random value of at least 32 bytes. The local-only `/break-glass/session/new` route requires that deployment token as well as the break-glass account password. Recovery sessions expire after 15 minutes. Normal sessions expire after 12 hours.

Set `NAVISHAI_APP_HOST` to the public application host in production so password reset and invitation emails use valid HTTPS links.

## Shared email intake

An Owner or Admin adds a shared inbox with a lowercase credential key. Put its webhook secret in Rails credentials at `shared_email.<credential_key>.webhook_secret`, or set `NAVISHAI_SHARED_EMAIL_<UPPERCASE_CREDENTIAL_KEY>_WEBHOOK_SECRET` to a random value of at least 32 bytes.

The forwarding service must post the raw RFC 5322 message to the inbox endpoint. Set `X-NavishAI-Timestamp` to the current Unix time and `X-NavishAI-Signature` to the lowercase HMAC-SHA256 hex digest of `timestamp.webhook_key.raw_email`. NavishAI accepts a five-minute clock skew, limits each source message to 10 MiB, and limits extracted message text to 1 MiB. Inbox settings separate safe retries from terminal deliveries that need review. Each inbound message freezes its first valid `Reply-To` address as the reply target, or its `From` address when `Reply-To` is absent or invalid.

To send replies, put SMTP settings in Rails credentials at `shared_email.<credential_key>.smtp` with `address`, `port`, `user_name`, `password`, and optional `authentication` keys. You can instead set the matching `NAVISHAI_SHARED_EMAIL_<UPPERCASE_CREDENTIAL_KEY>_SMTP_ADDRESS`, `_PORT`, `_USER_NAME`, `_PASSWORD`, and `_AUTHENTICATION` environment variables. NavishAI sends plain text only after a signed-in workspace writer reviews the exact draft and presses **Send email**. An uncertain SMTP result blocks another send until a signed-in writer checks SMTP or the shared mailbox and marks the attempt as accepted or not sent.

Inbound and user-uploaded attachments stay quarantined unless a deployment configures `AttachmentScanner.default` with an adapter whose `scan(data:, content_type:, filename:)` method returns `AttachmentScanner::Result` with `clean`, `infected`, or `unavailable` status. Missing scanners and scanner errors fail closed. NavishAI accepts PDF, plain text, PNG, JPEG, and GIF by byte signature, with at most five files, 5 MiB per file, and 10 MiB in total. Only clean files can be downloaded or sent, and NavishAI checks their stored SHA-256 digest before either action.

## Intercom sync

An Owner or Admin adds an Intercom connection with the app ID and a lowercase credential key. Put the app access token and client secret in Rails credentials at `intercom.<credential_key>.access_token` and `intercom.<credential_key>.client_secret`. You can instead set `NAVISHAI_INTERCOM_<UPPERCASE_CREDENTIAL_KEY>_ACCESS_TOKEN` and `_CLIENT_SECRET`. The client secret must be at least 32 bytes.

Subscribe the Intercom app to its Contact, Company, Conversation, conversation-part redaction, and conversation-tag topics. Intercom posts to the unguessable endpoint shown on the connection page with `X-Hub-Signature: sha1=<hex>`, where the hex value is the HMAC-SHA1 of the exact JSON body with the client secret. NavishAI reads at most 1 MiB, checks the signature in constant time, checks the app ID, and retains each notification by Intercom notification ID and SHA-256 digest.

Webhook intake mirrors contacts, companies, conversations, customer and teammate replies, private notes, remote assignment, and connection-owned tags. Remote state and assignment remain visible source facts rather than overwriting the local Case workflow. Deletions retire source identities and their match keys. Part redaction hides the linked content from current case views. Local notes, assignment, tags, and untag actions on an Intercom-backed Case create a frozen user-attributed sync operation. NavishAI matches the signed-in User and assignment target to Intercom admins by exact email. Definite configuration or API rejection may retry up to five times; a timeout, network failure, interrupted claim, or local failure after a remote call stops for human review instead of risking a duplicate write.

A workspace writer can save a plain-text Intercom draft. Each customer-facing reply requires that writer to sign in, review the current conversation, and press **Send to Intercom**. NavishAI binds the form to the newest synced conversation part, matches the signed-in User to an Intercom admin by exact email, and freezes the body, source part, remote conversation, admin, and human actor before the API call. A definite rejection opens the draft for a fresh command. An uncertain result blocks resend until a signed-in writer checks Intercom and records the exact remote part ID or marks the attempt not sent.

**Reconcile** retries safe inbound and outbound failures, then walks Intercom's cursor-paged conversation list to repair missed events and drift. NavishAI calls only `https://api.intercom.io`, uses API version 2.16, follows no redirects, and bounds network time and response bytes. This sync does not grant customer-send authority.

## Knowledge sources

Managers, Admins, and Owners can maintain approved text, ingest plain-text uploads, store reviewed URL snapshots, and register Intercom Help Center snapshots. URL ingestion accepts HTTPS only, rejects credentials and any DNS answer in a private or reserved network, pins the checked address for TLS, rechecks every redirect, and accepts at most 1 MiB of plain text or HTML. Uploaded knowledge must pass the configured attachment scanner and must contain plain text. PostgreSQL full-text search uses only the current version of active sources; expired and deleted versions retain stable citation links and warnings.

## Execution runner

Set `NAVISHAI_RUNNER_SHARED_SECRET` to the same random value of at least 32 bytes for Rails and the Go runner. Rails uses `NAVISHAI_RUNNER_ADDRESS`, which defaults to `http://127.0.0.1:8081`. Cleartext HTTP works only on a loopback address; other addresses must use HTTPS. Set `NAVISHAI_RUNNER_BIND_ADDRESS` to change the Go listener from `127.0.0.1:8081`. Set `NAVISHAI_RUNNER_STATE_PATH` to change its durable admission store from `tmp/runner-admissions.json`.

Start the runner with:

```sh
NAVISHAI_RUNNER_SHARED_SECRET='a-random-secret-of-at-least-32-bytes' go run ./runner/cmd/navishai-runner
```

For a runner on another host or container, set `NAVISHAI_RUNNER_TLS_CERT_FILE` and `NAVISHAI_RUNNER_TLS_KEY_FILE` together. Rails requires HTTPS for every non-loopback runner address. Set `NAVISHAI_RUNNER_CA_FILE` when a private CA issues the runner certificate. Rails adds that CA to the operating system roots rather than replacing them. Do not disable certificate checks. The runner keeps cleartext HTTP only for its default loopback bind.

Protocol `v1` signs the Unix timestamp, uppercase HTTP method, canonical path, and SHA-256 body digest with HMAC-SHA256. The runner accepts a five-minute clock skew and retains accepted idempotency keys before it replies. `GET /livez` and `GET /readyz` expose process and protocol health. Rails uses short network deadlines and does not follow redirects.

### Public-web search

Set `NAVISHAI_WEB_SEARCH_PROVIDER=searxng` and `NAVISHAI_SEARXNG_URL` to an HTTPS SearXNG origin. Loopback HTTP is allowed for local development. `NAVISHAI_WEB_SEARCH_STATE_PATH` can set a separate durable idempotency file; it defaults to `<NAVISHAI_RUNNER_STATE_PATH>.web-search`. Keep this file across runner restarts.

The signed `POST /v1/tools/web-search` endpoint accepts only minimized queries from Rails. The runner bounds provider time and bytes, rejects redirects, accepts only HTTPS evidence links without credentials or fragments, normalizes dates and excerpts, deduplicates links, and records observed cost units. Search results are untrusted evidence. Rails shows them for human review, stores stable `public-web://` citations, and marks them as untrusted in later run context. Current runtime adapters keep their native web-search features disabled; a future adapter may register native search only when it returns the same auditable structured contract. This search endpoint does not grant general runner or agent-runtime egress.

A writer may extract text only from an immutable result URL on that task. Rails resolves every DNS answer, rejects local and reserved networks, pins the checked address while keeping TLS host checks, and repeats those checks after each redirect. It accepts at most 1 MiB of plain text or HTML, strips active HTML, and stores the final URL, dates, SHA-256 digest, and text as an immutable snapshot. The review page and run context mark the snapshot as untrusted and bound its preview. Extraction does not add the page to durable memory.

## Self-hosted memory

NavishAI supports only a customer-run Supermemory Local server. Install the pinned 0.0.8 binary and verify its release checksum with `script/install_supermemory`. The supported upstream local build is one binary rather than a Docker image. Keep its data directory on persistent storage and disable telemetry:

```sh
script/install_supermemory
SUPERMEMORY_DATA_DIR=storage/supermemory SUPERMEMORY_DISABLE_TELEMETRY=1 tmp/supermemory/bin/supermemory-server
```

Complete Supermemory's first-boot local model setup, then put its generated `sm_...` key in Rails credentials at `memory.supermemory_api_key` or set `NAVISHAI_SUPERMEMORY_API_KEY`. `NAVISHAI_SUPERMEMORY_ADDRESS` defaults to `http://127.0.0.1:6767`; non-loopback servers require HTTPS. NavishAI rejects the managed Supermemory host, uses `superrag` indexing so PostgreSQL stays authoritative, and binds every index and search call to Organisation and Workspace metadata plus the Workspace container tag. The current Supermemory Lite binary enforces a 10,000-document licence cap; do not operate it as an uncapped index. Back up `SUPERMEMORY_DATA_DIR` before an upgrade. Version 0.0.8 repairs a vector-loss bug in the prior 0.0.7 upgrade path; do not downgrade a populated store.

Messages and resolved or closed Case outcomes create scoped episodic Memory records in the same PostgreSQL transaction as their source. Agent facts and preferences remain proposals until a Manager, Admin, or Owner accepts them. Only those roles may publish procedural memory. Each published record creates a durable index entry after commit and uses its stable Memory key as the engine document identity. An index outage never rolls back the source Case or changes PostgreSQL authority.

Run preparation asks the engine for at most eight current, indexed, time-eligible records from the task's inherited scopes, then loads their content from PostgreSQL. Selection sorts by relevance and stable Memory key, limits each record to 4 KiB and the full memory context to 16 KiB, and separates human corrections, source records, and inferences. Each item carries a `memory://` citation. The Execution run freezes the selected records, ranks, relevance scores, context, and `retrieved_memory` disclosure; a runtime must allow that data class. Artifact output can cite only Memory records selected for its exact run. Retrieved memory is marked as context rather than instruction, and current source records and approved knowledge take precedence. NavishAI stores explicit Memory records and selection facts, not hidden chain of thought. Until degraded mode is added, an unavailable engine fails run preparation when indexed eligible memory exists.

The Memory page lets Managers, Admins, and Owners inspect all Workspace records. Members see only records selected for runs on tasks they own; Viewers have no Memory access. Index and record views write user-attributed access audits without copying Memory content into the audit log. Members may propose corrections to records they can inspect. Managers, Admins, and Owners review those proposals, and their own corrections publish at once. An accepted correction creates a human-authority record and keeps the prior record as immutable history. Retention may be indefinite or end at a set time.

Managers, Admins, and Owners may tombstone a record with a reason. The tombstone excludes it from PostgreSQL retrieval at once. External index removal runs after commit and records each attempt as pending, removing, removed, failed, or unknown; failed or uncertain attempts remain visible for a safe retry. Run preparation locks selected records and rejects a selection that was deleted, superseded, expired, or lost its indexed state before the run was created.

When retrieval fails, a non-memory-critical specialist run continues with no recalled Memory, freezes `degraded` on the run, discloses no `retrieved_memory`, and shows the outage. PostgreSQL source work and Memory capture remain durable. Once an index attempt fails or becomes uncertain, later capture stays queued instead of calling the failed engine again. A Manager, Admin, or Owner can rebuild the index to force safe, stable-key retries. NavishAI never uses a managed fallback. See [MEMORY_ARCHIVE.md](./MEMORY_ARCHIVE.md) for the complete Workspace export/import format and restore checks.

The deterministic scripted adapter under `runner/internal/scripted` proves success, retry, timeout, cancellation, malformed-output, and policy-denial behavior without a model or network access. Its bounded JSON fixtures are test and demo inputs, not a live runtime.

Build `runner/cmd/navishai-exec` beside the runner before enabling process execution. The supervisor accepts only exact approved executables inside configured executable roots, resolves symlinks before launch, and passes only named run credentials into the child. An executable inside an allowed directory still cannot run until it appears in the approval set. The helper applies CPU, memory, file-descriptor, and process limits; bounds output; enforces the wall deadline and cancellation; terminates the process group; and waits for the child. Linux Landlock limits reads to configured runtime and executable roots and limits writes to the run's working root. Seccomp blocks socket calls by default.

A networked run must name a supervisor-owned egress profile bound to its exact approved executable. The profile supplies a paired subordinate user namespace and network namespace plus optional proxy and TLS settings. Deployment creates the namespaces for the dedicated runner UID, maps that UID to a nonzero namespace UID, and gives the network namespace a deny-by-default firewall or an allowlisting proxy. A profile is not an instruction to open host networking, and namespace identity does not prove firewall policy.

Build `runner/cmd/navishai-netns-launch/main.c` as `navishai-netns-launch` beside `navishai-exec`. This small, single-threaded launcher joins the subordinate user namespace first and its owned network namespace second. It then locks securebits, clears all capability sets, sets `no_new_privs`, and starts the Go helper. The helper applies Landlock and Seccomp; Seccomp blocks namespace and mount changes so every descendant keeps the same boundary. Neither binary needs setuid or file capabilities. A missing, mismatched, malformed, or wrong-executable profile fails closed. Runs without a profile continue to deny socket and io_uring setup calls.

The signed `POST /v1/runtimes/detect` runner endpoint reports only executables registered by installed adapters. It resolves each path, runs a bounded version probe, compares semantic versions with the adapter's maintained range, and returns declared capabilities plus non-secret account details. Owners and Admins use **Runtimes** to refresh those facts and approve routing profiles, workspace roles, tools, data classes, and time, step, tool-call, input-unit, and output-unit caps. PostgreSQL revokes approval when material detection facts change or an installation disappears. Subscription credentials stay on the runner and never enter this response or a business row.

The Codex subscription adapter detects `codex` 0.149.x and accepts only `codex login status` output that confirms a ChatGPT login. It invokes `codex exec` with JSONL output, no approvals, no user config or rules, read-only command sandboxing, disabled web search, and an ephemeral session. The adapter passes only `CODEX_HOME` into the supervised process, keeps token files on the runner, ignores reasoning text, and maps final text, tool status, usage, failure, timeout, and cancellation to canonical events. Unknown future JSONL event types do not break a successful turn; malformed or incomplete terminal output fails closed.

The opt-in upstream contract smoke uses the installed subscription and is off by default: `NAVISHAI_CODEX_LIVE_SMOKE=1 CODEX_HOME=/path/to/codex-home go test ./runner/internal/adapters/codex -run LiveSubscriptionSmoke`. It may consume subscription usage. The smoke checks the real CLI stream but does not replace normal supervisor boundary tests. Production invocation must bind the adapter to an approved egress profile; the smoke host runner does not prove that deployment boundary.

The Claude subscription adapter detects Claude Code 2.1.169 through 2.1.x and verifies `claude auth status` JSON as a first-party OAuth subscription rather than API or cloud-provider billing. Version 2.1.169 is the first release with safe mode. The adapter invokes print mode with stream-JSON output, safe mode, no session persistence, no MCP servers or built-in tools, `dontAsk` permissions, a bounded turn count, an explicit model, and a required egress profile. `CLAUDE_CONFIG_DIR` is the only Claude credential setting passed to the process. The parser checks the CLI version, session ID, empty tool set, permission mode, final result, permission denials, and usage; it ignores reasoning and unknown additive events.

The opt-in Claude smoke is also off by default: `NAVISHAI_CLAUDE_LIVE_SMOKE=1 CLAUDE_CONFIG_DIR=/path/to/claude-config go test ./runner/internal/adapters/claude -run LiveSubscriptionSmoke`. It may consume subscription usage and verifies the installed CLI stream, not the namespace firewall. Set `NAVISHAI_CLAUDE_SMOKE_MODEL` only when the account needs a model other than `sonnet`.

The Grok adapter supports Grok Build 1.0.4 through 1.0.x over Agent Client Protocol v1. It launches `grok agent --no-leader stdio`, requires cached subscription authentication during the ACP handshake, advertises no client file or terminal capabilities, supplies no MCP servers, and fails the run if Grok requests a tool, permission, terminal, or file operation. `GROK_HOME` remains on the customer runner. Production use also requires an approved egress profile and the runner filesystem/process boundary because Grok ACP does not provide a complete built-in no-tools mode.

Its live smoke is opt-in: `NAVISHAI_GROK_LIVE_SMOKE=1 GROK_HOME=/path/to/grok-home go test ./runner/internal/adapters/grok -run LiveSubscriptionSmoke`. It may consume subscription usage and does not replace supervisor tests. Set `NAVISHAI_GROK_SMOKE_MODEL` only when the account does not expose `grok-code-fast-1`.

The Cursor adapter supports Cursor CLI ACP releases from 2026.03.11 through the maintained 2026 date range. It prefers `cursor-agent` over the `agent` alias, launches `acp`, requires the advertised `cursor_login` method, advertises no client file or terminal capabilities, supplies no MCP servers, and rejects every reverse request and tool event. Cursor has no supported config-home override, so deployment must approve the existing browser-login home explicitly; Landlock still limits readable paths and keeps writes in the isolated run directory. Draft ACP usage is recorded only when Cursor supplies it.

Its live smoke is opt-in: `NAVISHAI_CURSOR_LIVE_SMOKE=1 NAVISHAI_CURSOR_HOME=/home/customer go test ./runner/internal/adapters/cursor -run LiveSubscriptionSmoke`. It may consume subscription usage and verifies ACP compatibility, not the production sandbox.

Runner events post to `/webhooks/runner-events` with the same HMAC headers plus `X-NavishAI-Workspace-Key`. Admission freezes the selected installation identity, adapter, routing profile, primary or fallback reason, disclosed data classes, and input/output unit caps. Every adapter stops before it emits output when reported usage exceeds those caps; the Rails ledger also rejects an over-budget usage event. PostgreSQL stores each run attempt and ordered event. Exact event replay is idempotent; changed, out-of-order, cross-workspace, over-budget, and invalid terminal events fail closed.

Completed Support and Customer Success Crew runs publish strict artifact schema `1` JSON with a role-bound `kind`, body, explicit uncertainty, one or more workspace-checked citations, conflicts, change requests, and review outcome. Investigations, drafts, intervention plans, and reviews are append-only and versioned. A review freezes the exact draft or intervention plan it saw. A rerun freezes the prior review and its requested changes into the next admission context, which is bounded at 128 KiB on both Rails and Go. Invalid or stale output rolls the completion event back instead of creating an uncited or mismatched result. These records propose work only; they cannot send or schedule a customer message.

## Account health and renewal risk

Managers, Admins, and Owners can import up to 2 MiB or 500 rows of account data through the Accounts page or the authenticated JSON endpoint at `POST /workspaces/:workspace_id/account-api-inputs`. Each record needs `source_id` and `account_name`; it may add `account_domain`, `contact_name`, `contact_email`, `renewal_on`, `contract_value`, `active_users`, and `licensed_seats`. Reusing a source ID is idempotent only when its values match. Changed source facts need a new source ID so prior facts remain retained.

NavishAI recalculates after imported inputs and committed conversation, note, Case, priority, or SLA changes. A deployment schedule can run the same deterministic pass across every Workspace:

```sh
bin/rails runner 'Workspace.find_each { |workspace| AccountHealth.recalculate_due!(workspace:) }'
```

Each snapshot stores its score, risk band, renewal date, trigger, prior snapshot, and typed signals. Signals keep value, source locator, time range, weight, risk points, and a stable `health://` citation. A score or risk-band change opens a review only when it crosses the material threshold; a renewal inside 90 days and a human request also open one. Customer Success runs receive the deterministic snapshot as facts, must cite retained Account, conversation, knowledge, web, Memory, or health-signal evidence, and must state uncertainty. Their interventions remain proposals for a human owner and cannot send to a customer.

The Account health scorecard designer maps a human goal to selected retained signals, bounded weights, and two health-band thresholds. Each proposal is an immutable version with a plain rule explanation. Writers may preview and backtest a version against up to 500 retained assessments. Owners and Admins may publish a tested version or roll future scoring back to an earlier tested version. Publishing never rewrites prior assessments; each new assessment records the exact version it used.

NavishAI creates in-app and email alerts for assignments, work that needs review, SLA thresholds, delivery and integration failures, blocked Crew work, and completed Crew work. Alert emails contain only the alert kind, workspace name, time, and a sign-in link; customer content stays inside NavishAI. Configure Action Mailer for the deployment as you would for verification, reset, and invitation mail.

Owners and Admins can register outbound webhook endpoints from the Webhooks page. Each endpoint selects alert categories and a credential key. Set `NAVISHAI_WEBHOOK_<CREDENTIAL_KEY>_SIGNING_SECRET` or `outbound_webhooks.<credential_key>.signing_secret` in Rails credentials. NavishAI sends content-free JSON with a stable event ID and signs the exact body in `X-NavishAI-Signature` using HMAC-SHA256. Receivers should deduplicate on `X-NavishAI-Event`. Delivery resolves and pins public DNS, rejects private or mixed answers, does not follow redirects, retries network and 5xx failures up to five times, and keeps 4xx failures for review.

The Crew task page polls its workspace-scoped run record while an attempt is active. Case tasks use the Support Crew; Account tasks use the Customer Success Crew. A writer can retry an unconfirmed admission with its original idempotency key or start a later attempt after a terminal result. The page keeps blocked, degraded, failed, canceled, and completed states distinct and exposes safe run IDs, event sequence, policy version, usage, and failure codes for operator checks. An active run blocks task cancellation until the runner records a terminal event.

## Checks

Run the full local check suite with:

```sh
bin/ci
```

The suite checks Ruby and Go formatting, audits Ruby and import-map dependencies, scans Rails code, runs Rails and system tests, vets and tests the Go runner, and runs the Rails-to-Go protocol contract.

GitHub Actions runs this same check set only when started by hand. Run `bin/ci` before each development checkpoint; enable automatic pull-request checks again for release work when Actions use is approved.

### Retention expiry

Owners set separate customer-content and security-audit periods under **Data controls**. When retention is enabled, the production queue requests expiry each day. An Owner can also request it from the same page. Content expiry first removes expired attachment objects and indexed Memory documents. It then replaces expired plaintext and source identifiers in PostgreSQL with fixed tombstones while retaining tenant links, trusted times, outcomes, and audit history. A failed external removal stops database expiry and stays visible for retry on the next run. Audit expiry removes actor, network, request, and metadata fields after its later cutoff, but keeps the action, subject, trusted time, and an expiry mark so ledger links remain valid. Back up before shortening either period: completed expiry cannot be undone.

Owners can download the complete logical Workspace snapshot from the same page. See [WORKSPACE_ARCHIVE.md](./WORKSPACE_ARCHIVE.md) for its scope and security boundary.

Run focused checks while working:

```sh
bin/rails test
go test ./...
```

The Rails control plane exposes `GET /up`. The runner exposes `GET /livez` and `GET /readyz` on port 8081 by default.
