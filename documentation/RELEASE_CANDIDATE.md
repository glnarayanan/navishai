# Phase release-candidate record

NavishAI is build-complete and pilot-ready for owner review. This record describes the source stack, not a published package, launch, live deployment, security certification, product validation, or market result.

## Included review boundary

The stacked source includes:

- local password, generic OpenID Connect, invitation, reset, verification, and protected break-glass access;
- isolated Organisations and Workspaces with five roles and an append-only audit trail;
- the native Support and Customer Success flows in `BUILD.md`, including human-only email and Intercom send;
- bounded Crew work, provider-neutral runtime routing, four subscription adapters, guarded public-web research, and durable execution records;
- PostgreSQL-backed source facts and self-hosted Supermemory indexing, recall, correction, degraded mode, and reconstruction;
- notifications, signed outbound webhooks, retention, complete Workspace export/import, and confirmed Workspace deletion;
- Compose and native Linux packaging, an experimental cloud-neutral Helm chart, backup and restore tools, and upgrade preflight; and
- a seeded demo, dependency record, CycloneDX SBOM, release manifest, threat model, and operator guides.

`bin/ci` is the source checkpoint. It runs Ruby and Go style checks, dependency audits, Brakeman, the full Rails and browser suites, Go vet and tests, the Rails-to-runner contract, seed checks, and the SBOM check. Record host-specific omissions instead of treating a partial run as a green release checkpoint.

## Phase-completion checkpoint

The deterministic M6 proof is at `5e74ed6cce04cb730c376b0328c7a814812feae1`, strengthened at `2f1f876884866ac0046a81b5795e7570669ee96d`. It joins the accepted M0-M5 seams without adding product scope. The proof covers the Support resolution and human-send journey, full outcome explanation, Account dossier, health intervention and observed review, safe reliability recovery, GET-only Intercom backfill through verified Workspace restoration and Memory reconstruction, and governed canary and future-only rollback. The only integrated fix, `1a890c664babf93766f6c88ecaf9c0ed9d7419ac`, isolates Active Storage roots by Rails test worker so archive digest checks cannot race another worker's files.

On Linux 6.1 x86-64 with Ruby 4.0.6, Go 1.27.0, PostgreSQL 15.19, and pgvector 0.8.6, three integrated tests passed with 90 assertions and 172 focused adversarial tests passed with 1,530 assertions. The full `bin/ci` checkpoint passed style checks for 509 Ruby files and Go, both dependency audits, Brakeman with no warnings, 718 Rails tests with 5,104 assertions, 60 browser tests with 957 assertions, Go vet and tests, all three native Linux builds, the Rails-to-runner contract, seed replant, and the 84-component SBOM. A native custom-format PostgreSQL backup with SHA-256 `83ad5f35cc32d063518a8773718b0ac939d70a912e13f49bb5c39cdc57ac76d1` restored into an isolated database with 105 public tables, 61 applied migrations, and pgvector 0.8.6.

The browser suite covered desktop and 320-pixel mobile views, keyboard focus, semantic structure, reduced motion, safe wrapping, and failure, degraded, and recovery states. Inspected final captures showed no visible clipping or overflow, and an Impeccable layout scan found no defects. Ui.sh was unavailable in this thread. These checks are source evidence only. They do not mean NavishAI has been launched, certified, deployed, or validated.

The 27 August rebaseline started from `fbf65f0b3c268f650a2489035236d7fb82e9467d` on Linux 6.1 x86-64 with Ruby 4.0.6, Go 1.27.0, PostgreSQL 15.19, pgvector 0.8.6, and Chrome for Testing 152.0.7977.64. A fresh orb exposed a system-test setup defect: Selenium downloaded Chrome only after the test class had already resolved its browser path, so all 45 browser tests failed before making an assertion. Commit `3f06a961797870e4aa2b3a4f96fc37c5fbf9336d` now asks Selenium Manager for Chrome before driver setup. With an empty Selenium browser cache, the first plain `bin/rails test:system` invocation passed 45 tests and 656 assertions without skips. The full `bin/ci` checkpoint then passed 422-file Ruby style, Go style, gem and Importmap audits, Brakeman with no warnings, 547 Rails tests with 3,341 assertions, 45 browser tests with 656 assertions, the native Linux Go suite and three Linux binary builds, the Rails-to-runner contract, seed replant, and the 84-component SBOM check.

Focused release checks passed 14 tests with 75 assertions for backup, verification, restore confirmation and state coverage, upgrade preflight, the pgvector 0.8.1-to-0.8.6 migration boundary, and container privilege settings. An uncached native Linux Go run passed `go vet ./...` and `go test ./...`, then built x86-64 runner, executor, and namespace-launcher binaries. SBOM output and a deterministic release manifest matched the checked commit and artifact digest. The host PostgreSQL check had no pending migrations, and a custom-format `navishai_test` backup passed checksum and catalog verification; its isolated restore matched 49 migrations, 87 public tables, and pgvector 0.8.6. This host has only pgvector 0.8.6 available and no Docker or Podman executable, so it could not run a live 0.8.1 volume upgrade, production image construction, the four-database Compose backup and full state archives, Compose restore, or Compose upgrade preflight.

## Known gaps before a public release

### Host boundaries

- Production image construction, a live pgvector 0.8.1-to-0.8.6 volume upgrade, the full Compose backup and isolated restore, and Compose upgrade preflight still need a Linux host with Docker Engine and Compose v2. The Linux orb rebaseline covered their source-controlled regression tests and the native PostgreSQL restore described above, not these live Compose paths.
- The M6 orb had neither Docker nor Podman, so it could not add live container evidence for those paths.
- The Helm chart is experimental. It does not yet have the same live upgrade, restore, and platform-security evidence as Compose and native Linux.

### Credential boundaries

- Live OpenID Connect, SMTP, Intercom, SearXNG, object-store, and subscription-runtime smoke tests need deployment-owned endpoints or credentials. The default suites use protocol fixtures and must not consume customer accounts.

### Legal and signing boundaries

- Final source-licence text and contributor terms still need legal review. Do not publish a release or describe the licence as OSI-approved before that review.
- No project release-signing identity has been set up. Current manifests provide SHA-256 integrity, not signed provenance or a SLSA claim.

### Deployment boundaries

- GitHub Actions is manual-only and has not been used for this build. Local repository checks are the current verification record.
- The self-hosted Supermemory Lite build has a 10,000-document licence cap. Operators must size and monitor within that limit.
- A real deployment still needs operator-owned TLS, secrets, backup storage, restore rehearsal, firewall policy, runtime namespace policy, and post-install checks. Repository tests do not certify those controls on an unknown host.

### Pilot boundary

- No paid pilot or production adoption evidence exists in this record. Product validation remains an owner decision after real use.
- The owner still controls pilot scope, customer approval, credentials, deployment, legal review, signing, and every market claim.

## Handoff rule

Use [RELEASE.md](./RELEASE.md) to create immutable artifacts only after the Owner approves public-release work, legal text, a version, release signing, and any use of GitHub Actions. Use [OPERATIONS.md](./OPERATIONS.md) for the deployment backup, restore test, upgrade preflight, and rollback boundary. State any environment-specific test that was not run; do not turn a source check into a deployment or certification claim.
