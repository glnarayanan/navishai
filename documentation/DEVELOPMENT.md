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

The forwarding service must post the raw RFC 5322 message to the inbox endpoint. Set `X-NavishAI-Timestamp` to the current Unix time and `X-NavishAI-Signature` to the lowercase HMAC-SHA256 hex digest of `timestamp.webhook_key.raw_email`. NavishAI accepts a five-minute clock skew, limits each source message to 10 MiB, and limits extracted message text to 1 MiB. Inbox settings separate safe retries from terminal deliveries that need review. Customer sending remains disabled until the separate human-send flow is configured.

## Checks

Run the full local check suite with:

```sh
bin/ci
```

The suite checks Ruby and Go formatting, audits Ruby and import-map dependencies, scans Rails code, runs Rails tests, vets the Go runner, and runs Go tests.

Run focused checks while working:

```sh
bin/rails test
go test ./...
```

The Rails control plane exposes `GET /up`. The runner skeleton exposes `GET /livez` and `GET /readyz` on port 8081 by default. Set `NAVISHAI_RUNNER_ADDRESS` to change the runner bind address.
