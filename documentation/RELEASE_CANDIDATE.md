# Phase release-candidate record

NavishAI is build-complete and pilot-ready for owner review. This record describes the source stack, not a published package, launch, live deployment, security certification, product validation, or market result.

## Included review boundary

The stacked source includes:

- local password, generic OpenID Connect, invitation, reset, verification, and protected break-glass access;
- isolated Organisations and Workspaces with five roles and an append-only audit trail;
- the native Support and Customer Success flows in `BUILD.md`, including human-only email and Intercom send;
- bounded Crew work, provider-neutral runtime routing, four subscription adapters, in-app provider connections with direct OpenAI and Anthropic API-key execution through the runner-held vault, guarded public-web research, and durable execution records;
- PostgreSQL-backed source facts and self-hosted Supermemory indexing, recall, correction, degraded mode, and reconstruction;
- the next-phase resolution contracts, claim grounding, human-edit provenance, Explain this outcome, usage and cost rollups, Account dossier, typed business evidence, human-owned interventions, reliability cockpit, verified archive round trips, historical Intercom backfill, and governed policy change;
- notifications, signed outbound webhooks, retention, complete Workspace export/import, and confirmed Workspace deletion;
- a reference ClamAV attachment-scanner adapter, a daily scheduled Account-health pass, knowledge document uploads in text, Markdown, HTML, PDF, and ZIP form, and optional Exa or Tavily search adapters beside SearXNG;
- Compose and native Linux packaging, an experimental cloud-neutral Helm chart, backup and restore tools, and upgrade preflight; and
- a seeded demo, dependency record, CycloneDX SBOM, release manifest, threat model, and operator guides.

`bin/ci` is the source checkpoint. It runs Ruby and Go style checks, dependency audits, Brakeman, the full Rails and browser suites, Go vet and tests with the process-isolation suite required, the Rails-to-runner contract, seed checks, and the SBOM check. Record host-specific omissions instead of treating a partial run as a green release checkpoint.

## Phase-completion checkpoint

The M0–M6 roadmap is complete at the source level. The deterministic M6 proof in `test/integration/phase_completion_proof_test.rb` exercises the accepted seams rather than inserting approved state: ordered `ExecutionLedger` terminal events, `CrewArtifactPublisher`, `ResolutionContractEvaluator`, `CrewWork` review transitions, `HumanEmailSend`, `OutcomeExplanation`, `AccountDossier`, `CustomerSuccessInterventionWorkflow`, `ReliabilityCockpit` and `ReliabilityRecovery`, `IntercomHistoricalBackfill`, the Workspace archive round trip with Memory reconstruction, and `GovernedPolicyChange` canary and rollback. It merged on 28 August 2026 in PR #82 (`2e6dd3f`).

The 6 September 2026 checkpoint ran on branch `claude/docs-build-contracts-review-nx2rly` from main `5e35f5e3d3d536f0006bdfc0af47474f0dbcf459` on a fresh Linux 6.18 x86-64 host prepared by `script/prepare_check_host`: Ruby 4.0.6 built from the `ruby_4_0` branch at 4.0.6 patch level 0, Go 1.27.0, PostgreSQL 16.15 with pgvector 0.8.6 built from the pinned source revision, and Chromium 141 with a matching ChromeDriver. In that environment:

- the M6 integrated proof passed 3 tests with 97 assertions;
- the full Rails suite passed 874 tests with 6,546 assertions and no skips;
- the browser suite passed 67 system tests with 1,159 assertions and no skips, covering the landing page at desktop and 320-pixel widths after the hero and self-hosting visual changes;
- RuboCop inspected 539 files with no offences, Brakeman reported no warnings, and the gem and Importmap audits passed;
- Go vet, the 17-package Go suite, the three Linux binary builds, and the Rails-to-runner scripted execution and provider catalog contract passed;
- the seed replant and the 89-component SBOM check passed.

One check could not run on that host and is recorded as an omission, not a pass: the supervisor's process-boundary tests skip because the kernel has no Landlock, and with `NAVISHAI_REQUIRE_ISOLATION_TESTS=1`, as `bin/ci` sets it, they fail rather than skip. The runner isolation evidence therefore still comes from the 27 August native Linux run below. Docker and Podman were not available for the live Compose paths.

The 27 August rebaseline started from `fbf65f0b3c268f650a2489035236d7fb82e9467d` on Linux 6.1 x86-64 with Ruby 4.0.6, Go 1.27.0, PostgreSQL 15.19, pgvector 0.8.6, and Chrome for Testing 152.0.7977.64. Commit `3f06a961797870e4aa2b3a4f96fc37c5fbf9336d` asks Selenium Manager for Chrome before driver setup so a fresh host runs the browser suite without skips. That `bin/ci` checkpoint passed Ruby and Go style, gem and Importmap audits, Brakeman, 547 Rails tests, 45 browser tests, the native Linux Go suite including the isolation boundary, three Linux binary builds, the runner contract, seed replant, and the SBOM check. Focused release checks passed 14 tests for backup, verification, restore confirmation, upgrade preflight, the pgvector 0.8.1-to-0.8.6 migration boundary, and container privilege settings. A custom-format `navishai_test` backup passed checksum and catalog verification, and its isolated restore matched the migrations, public tables, and pgvector 0.8.6.

These checks are source evidence only. They do not mean NavishAI has been launched, certified, deployed, or validated.

## Known gaps before a public release

### Host boundaries

- Production image construction, a live pgvector 0.8.1-to-0.8.6 volume upgrade, the full Compose backup and isolated restore, and Compose upgrade preflight still need a Linux host with Docker Engine and Compose v2. Source-controlled regression tests and the native PostgreSQL restore cover them; the live Compose paths have not run.
- The runner's process-isolation suite needs a Linux kernel with Landlock and seccomp. Hosts without it skip those tests by default and fail them under `bin/ci`.
- A host that cannot reach Selenium Manager's download service runs the browser suite with `CHROME_BIN`, `CHROMEDRIVER_BIN`, and, when tests must run as root, `CHROME_ARGS="--no-sandbox"`.

### Deferred scope

- Helm parity with Compose and native Linux is deferred. The chart remains experimental without live upgrade, restore, or platform-security evidence.
- S3-compatible object storage is deferred. Only the local disk service is configured and tested; treat the Helm object-storage note as a future path.
- The macOS host-trusted execution mode for Codex and Cursor is marked for redesign as a server-side companion boundary. It stays disabled unless the deployment owner enables it and is recorded as an operator-accepted risk in the threat model.
- Public-web search offers SearXNG, Exa, or Tavily per runner; a runtime's own native search and per-Workspace provider selection remain roadmap M7.3 work. Knowledge uploads accept text, Markdown, HTML, PDF, and ZIP bundles; Intercom Help Center knowledge is still a manual snapshot rather than a synchronised source (M7.2), and provider-backed knowledge connections (M7.4) do not exist yet.

### Credential boundaries

- Live OpenID Connect, SMTP, Intercom, SearXNG, Exa, Tavily, ClamAV, object-store, provider API-key, and subscription-runtime smoke tests need deployment-owned endpoints or credentials. The default suites use protocol fixtures and must not consume customer accounts.

### Signing boundary

- No project release-signing identity has been set up. Current manifests provide SHA-256 integrity, not signed provenance or a SLSA claim.

### Deployment boundaries

- GitHub Actions is manual-only and has not been used for this build. Local repository checks are the current verification record; record each checkpoint's commit, host, and omissions here.
- The self-hosted Supermemory Lite build has a 10,000-document licence cap. Operators must size and monitor within that limit.
- A real deployment still needs operator-owned TLS, secrets, backup storage, restore rehearsal, firewall policy, runtime namespace policy, an optional ClamAV daemon, and post-install checks. Repository tests do not certify those controls on an unknown host.

### Pilot boundary

- No paid pilot or production adoption evidence exists in this record. Product validation remains an owner decision after real use.
- The owner still controls pilot scope, customer approval, credentials, deployment, signing, and every market claim.

## Handoff rule

Use [RELEASE.md](./RELEASE.md) to create immutable artifacts only after the Owner approves public-release work, a version, release signing, and any use of GitHub Actions. Use [OPERATIONS.md](./OPERATIONS.md) for the deployment backup, restore test, upgrade preflight, and rollback boundary. State any environment-specific test that was not run; do not turn a source check into a deployment or certification claim.
