# NavishAI working agreements

Direct owner instructions override this file. Discover the active repository root; do not assume a host, editor, model, or agent.

## Authorities

Read [PRODUCT](./documentation/PRODUCT.md), [ARCHITECTURE](./documentation/ARCHITECTURE.md), [DOMAIN](./documentation/DOMAIN.md), [REBUILD_PLAN](./documentation/REBUILD_PLAN.md), and [STATUS](./documentation/STATUS.md) before implementation. The 30 September 2026 support-evaluation reset supersedes the old helpdesk thesis. Preserve Git history, not obsolete product behaviour.

## Boundaries

- Rails, Hotwire, PostgreSQL, and native jobs first. Use Go for the bounded execution interface when needed. Rails never invokes model CLIs or arbitrary shell commands.
- New production gems, Go modules, JavaScript pins, packages, and services need owner approval. No SPA or Python/ML stack without a demonstrated need and scoped decision.
- Isolate workspace reads, writes, jobs, evidence, and provider disclosure. Keep source provenance, immutable definitions, and attributable human decisions.
- Experts approve expectations. Machine proposals and uncalibrated judges are not truth. Do not invent coverage, accuracy, cost, or deployment claims.
- No helpdesk, customer sends, SLAs, account-health workflows, crew personas, or broad agent memory. No classifier training before labelled-data and cost evidence.
- Treat proprietary data, credentials, and untrusted source content with care. Never reset a non-disposable database as part of setup.

## Delivery

- State each substantial slice's goal, done checks, limits, and non-goals. Use the smallest complete solution.
- Use atomic Conventional Commits and small green stacked PRs. Inspect branch, remote, and worktree; leave user-owned changes alone. Never force-push or unexpectedly push to the default branch.
- Continue through assigned scope without routine checkpoint approval. Ask only for material scope, security, data, cost, destructive, credential, or dependency blockers. Safe independent work comes first.
- Do not create extra implementation threads unless the owner asks.
- Run native formatting, lint, focused and relevant broad tests. Review risk before handoff. Distinguish local, committed, pushed, merged, released, deployed, and customer-validated.
- Use available Impeccable and UI.sh guidance for meaningful UI work. Keep server-rendered pages, local assets, keyboard/focus access, responsive layouts, and honest empty/error/review states. Render and inspect affected desktop/mobile states.

## Documentation

Keep root entrypoints lean; durable detail belongs in `documentation/`. Update facts when behaviour, architecture, setup, or evidence changes; remove stale guidance. Private `.local-agent/research-context.md`, if present, must not leak into tracked material.
