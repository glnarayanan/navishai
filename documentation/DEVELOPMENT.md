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

## Knowledge sources

Managers, Admins, and Owners can maintain approved text, ingest plain-text uploads, store reviewed URL snapshots, and register Intercom Help Center snapshots. URL ingestion accepts HTTPS only, rejects credentials and any DNS answer in a private or reserved network, pins the checked address for TLS, rechecks every redirect, and accepts at most 1 MiB of plain text or HTML. Uploaded knowledge must pass the configured attachment scanner and must contain plain text. PostgreSQL full-text search uses only the current version of active sources; expired and deleted versions retain stable citation links and warnings.

## Execution runner

Set `NAVISHAI_RUNNER_SHARED_SECRET` to the same random value of at least 32 bytes for Rails and the Go runner. Rails uses `NAVISHAI_RUNNER_ADDRESS`, which defaults to `http://127.0.0.1:8081`. Cleartext HTTP works only on a loopback address; other addresses must use HTTPS. Set `NAVISHAI_RUNNER_BIND_ADDRESS` to change the Go listener from `127.0.0.1:8081`. Set `NAVISHAI_RUNNER_STATE_PATH` to change its durable admission store from `tmp/runner-admissions.json`.

Start the runner with:

```sh
NAVISHAI_RUNNER_SHARED_SECRET='a-random-secret-of-at-least-32-bytes' go run ./runner/cmd/navishai-runner
```

Protocol `v1` signs the Unix timestamp, uppercase HTTP method, canonical path, and SHA-256 body digest with HMAC-SHA256. The runner accepts a five-minute clock skew and retains accepted idempotency keys before it replies. `GET /livez` and `GET /readyz` expose process and protocol health. Rails uses short network deadlines and does not follow redirects.

The deterministic scripted adapter under `runner/internal/scripted` proves success, retry, timeout, cancellation, malformed-output, and policy-denial behavior without a model or network access. Its bounded JSON fixtures are test and demo inputs, not a live runtime.

Build `runner/cmd/navishai-exec` beside the runner before enabling process execution. The supervisor accepts only configured executable and working roots, resolves symlinks before launch, and passes only named run credentials into the child. The helper applies CPU, memory, file-descriptor, and process limits; bounds output; enforces the wall deadline and cancellation; terminates the process group; and waits for the child. Linux Landlock limits reads to configured runtime and executable roots and limits writes to the run's working root. Seccomp blocks socket calls. The helper fails closed when either boundary is unavailable, and this v1 profile does not support network-enabled runs.

Runner events post to `/webhooks/runner-events` with the same HMAC headers plus `X-NavishAI-Workspace-Key`. PostgreSQL stores each run attempt and ordered event. Exact event replay is idempotent; changed, out-of-order, cross-workspace, and invalid terminal events fail closed.

Completed Support Crew runs publish strict artifact schema `1` JSON with a role-bound `kind`, body, explicit uncertainty, one or more workspace-checked citations, conflicts, change requests, and review outcome. Investigation, draft, and quality-review artifacts are append-only and versioned. A quality review freezes the exact draft it saw. A rerun freezes the prior review and its requested changes into the next admission context, which is bounded at 128 KiB on both Rails and Go. Invalid or stale output rolls the completion event back instead of creating an uncited or mismatched result. These records propose work only; they cannot create or send an email draft.

The Crew task page polls its workspace-scoped run record while an attempt is active. A writer can retry an unconfirmed admission with its original idempotency key or start a later attempt after a terminal result. The page keeps blocked, degraded, failed, canceled, and completed states distinct and exposes safe run IDs, event sequence, policy version, usage, and failure codes for operator checks. An active run blocks task cancellation until the runner records a terminal event.

## Checks

Run the full local check suite with:

```sh
bin/ci
```

The suite checks Ruby and Go formatting, audits Ruby and import-map dependencies, scans Rails code, runs Rails and system tests, vets and tests the Go runner, and runs the Rails-to-Go protocol contract.

GitHub Actions runs this same check set only when started by hand. Run `bin/ci` before each development checkpoint; enable automatic pull-request checks again for release work when Actions use is approved.

Run focused checks while working:

```sh
bin/rails test
go test ./...
```

The Rails control plane exposes `GET /up`. The runner exposes `GET /livez` and `GET /readyz` on port 8081 by default.
