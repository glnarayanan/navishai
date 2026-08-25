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

`bin/ci` is the source checkpoint. It runs Ruby and Go style checks, dependency audits, Brakeman, the full Rails and browser suites, Go vet and tests, the Rails-to-runner contract, seed checks, and the SBOM check. Each stacked checkpoint passed it locally.

The final source candidate passed `bin/ci` on 24 August 2026: 510 Rails tests with 3,183 assertions and 33 browser tests with 413 assertions, plus all style, security, Go, protocol, seed, and SBOM checks. Impeccable type and layout detectors reported no mechanical findings. Direct browser review covered the seeded Support and Customer Success paths at 1,440 and 320 pixels with no page overflow.

## Known gaps before a public release

- Final source-licence text and contributor terms still need legal review. Do not publish a release or describe the licence as OSI-approved before that review.
- No project release-signing identity has been set up. Current manifests provide SHA-256 integrity, not signed provenance or a SLSA claim.
- GitHub Actions is manual-only and has not been used for this build. Local repository checks are the current verification record.
- The Helm chart is experimental. It does not yet have the same live upgrade, restore, and platform-security evidence as Compose and native Linux.
- Live OpenID Connect, SMTP, Intercom, SearXNG, object-store, and subscription-runtime smoke tests need deployment-owned endpoints or credentials. The default suites use protocol fixtures and must not consume customer accounts.
- The self-hosted Supermemory Lite build has a 10,000-document licence cap. Operators must size and monitor within that limit.
- A real deployment still needs operator-owned TLS, secrets, backup storage, restore rehearsal, firewall policy, runtime namespace policy, and post-install checks. Repository tests do not certify those controls on an unknown host.
- No paid pilot or production adoption evidence exists in this record. Product validation remains an owner decision after real use.

## Handoff rule

Use [RELEASE.md](./RELEASE.md) to create immutable artifacts only after the Owner approves public-release work, legal text, a version, release signing, and any use of GitHub Actions. Use [OPERATIONS.md](./OPERATIONS.md) for the deployment backup, restore test, upgrade preflight, and rollback boundary. State any environment-specific test that was not run; do not turn a source check into a deployment or certification claim.
