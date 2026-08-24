# NavishAI

NavishAI is an agent-first, human-governed workspace for Support and Customer Success. Specialist AI crews investigate, retrieve, analyse, draft, review, and remember. Humans retain customer communication and consequential authority.

The project is greenfield. The target is a secure, self-hostable, market-review-ready v1, not a synthetic prototype.

## Start here

1. Read [AGENTS.md](./AGENTS.md) for working agreements and architecture boundaries.
2. Read [documentation/BUILD.md](./documentation/BUILD.md) for the complete product decisions, Q1-Q74 interview ledger, done evidence, and autonomous stacked-PR plan.
3. Use [documentation/DEVELOPMENT.md](./documentation/DEVELOPMENT.md) to set up the application and run its checks.
4. Follow [documentation/DESIGN.md](./documentation/DESIGN.md) when building or reviewing product UI.
5. Use [documentation/DOMAIN.md](./documentation/DOMAIN.md) for canonical product terms.
6. Use [documentation/DEPLOYMENT.md](./documentation/DEPLOYMENT.md) for Compose, native Linux, and experimental Helm deployment.

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
