# V1 release-candidate record

NavishAI v1 is build-complete and market-review-ready for owner review. This record describes the source stack, not a published package, live deployment, security certification, or market result.

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

The 25 August Ruby 4.0.6 and pgvector 0.8.6 checkpoint passed setup, 406-file Ruby style, Go style, gem and Importmap audits, Brakeman, 520 Rails tests with 3,212 assertions, seed replant, and the 84-component SBOM check. The 33-test browser suite completed 376 assertions on macOS but retained six environment-specific failures: Chrome enforces a 500-pixel minimum window for five 320/375-pixel assertions, and local font rendering produces one 22-pixel link target where the test requires 24 pixels. Direct browser smoke testing at exact 1,440 and 320-pixel device viewports covered sign-in, Workspace selection, Cases, Accounts, and account health with no horizontal overflow. The Go runner cross-compiles and vets for Linux amd64, but the full native Linux runner suite, persistent PostgreSQL 15 upgrade smoke, and production container build still need a Linux container host before this becomes a green release checkpoint.

## Known gaps before a public release

- Final source-licence text and contributor terms still need legal review. Do not publish a release or describe the licence as OSI-approved before that review.
- No project release-signing identity has been set up. Current manifests provide SHA-256 integrity, not signed provenance or a SLSA claim.
- GitHub Actions is manual-only and has not been used for this build. Local repository checks are the current verification record.
- Podman 6.1 cannot currently boot its Fedora CoreOS machine on this macOS 26 host, so the production container build and live pgvector 0.8.1-to-0.8.6 volume upgrade remain Linux-host release checks.
- The Helm chart is experimental. It does not yet have the same live upgrade, restore, and platform-security evidence as Compose and native Linux.
- Live OpenID Connect, SMTP, Intercom, SearXNG, object-store, and subscription-runtime smoke tests need deployment-owned endpoints or credentials. The default suites use protocol fixtures and must not consume customer accounts.
- The self-hosted Supermemory Lite build has a 10,000-document licence cap. Operators must size and monitor within that limit.
- A real deployment still needs operator-owned TLS, secrets, backup storage, restore rehearsal, firewall policy, runtime namespace policy, and post-install checks. Repository tests do not certify those controls on an unknown host.
- No paid pilot or production adoption evidence exists in this record. Product validation remains an owner decision after real use.

## Handoff rule

Use [RELEASE.md](./RELEASE.md) to create immutable artifacts only after the Owner approves public-release work, legal text, a version, release signing, and any use of GitHub Actions. Use [OPERATIONS.md](./OPERATIONS.md) for the deployment backup, restore test, upgrade preflight, and rollback boundary. State any environment-specific test that was not run; do not turn a source check into a deployment or certification claim.
