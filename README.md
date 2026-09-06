# NavishAI

NavishAI is an agent-first, human-governed workspace for Support and Customer Success. Specialist AI crews investigate, retrieve, analyse, draft, review, and remember. Humans retain customer communication and consequential authority.

NavishAI is build-complete and pilot-ready for owner review. It is not yet a public release, a certified system, or proof of market demand. See the [implementation status](./documentation/STATUS.md) for the capability matrix, evidence, pending work, and known boundaries.

## Start here

1. Read [AGENTS.md](./AGENTS.md) for working agreements and architecture boundaries.
2. Read [documentation/PRODUCT.md](./documentation/PRODUCT.md) for the consolidated product specification, rules, and architecture.
3. Read [documentation/STATUS.md](./documentation/STATUS.md) for what is implemented, the evidence, and what remains.
4. Use [documentation/DEVELOPMENT.md](./documentation/DEVELOPMENT.md) to set up the application and run its checks.
5. Follow [documentation/DESIGN.md](./documentation/DESIGN.md) when building or reviewing product UI.
6. Use [documentation/DOMAIN.md](./documentation/DOMAIN.md) for canonical product terms.
7. Use [documentation/DEPLOYMENT.md](./documentation/DEPLOYMENT.md) for Compose, native Linux, and experimental Helm deployment.
8. Use [documentation/OPERATIONS.md](./documentation/OPERATIONS.md) for backup, restore tests, upgrades, and recovery.
9. Use [documentation/DEMO.md](./documentation/DEMO.md) to create the seeded review Workspace.
10. Use [documentation/RELEASE.md](./documentation/RELEASE.md) for SBOM, provenance, patch, and release rules.

The exact production dependency record is in [documentation/DEPENDENCIES.md](./documentation/DEPENDENCIES.md).

## Selected architecture

- Rails with server-rendered HTML, Hotwire, and import maps for the control plane
- PostgreSQL for authoritative tenant, business, security, policy, and execution state
- A Go execution runner behind a versioned, provider-neutral protocol
- Self-hosted Supermemory behind a replaceable memory contract
- Provider-neutral runtime and public-search registries
- No Node backend, React SPA, Vite pipeline, or runtime CDN dependency by default
- Agents never send customer messages in v1; an authenticated human reviews, edits, and deliberately presses Send

Amp is the initial implementation environment, but NavishAI must not depend on Amp, Codex, Grok, Cursor, or another coding tool. Discover the active checkout and keep setup reproducible across local clones, worktrees, containers, CI, and ephemeral remote environments.
