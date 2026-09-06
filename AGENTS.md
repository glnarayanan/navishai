# NavishAI working agreements

These instructions apply to every coding agent and human contributor in this repository. Direct owner instructions override this file.

## Read first

- Discover the active repository root. Do not assume an absolute path, host, user, editor, model, or coding agent.
- Read [documentation/PRODUCT.md](./documentation/PRODUCT.md) before changing architecture or product scope. It is the consolidated specification.
- Read [documentation/STATUS.md](./documentation/STATUS.md) before implementing anything. It records what exists, the evidence, pending work, and dated decisions; update it when implementation state changes.
- If .local-agent/research-context.md exists, use it only as private local research input. Do not copy its names, comparisons, or provenance into tracked files or public material unless the owner explicitly asks.
- NavishAI is greenfield. Do not invent existing behaviour that must be preserved, but do preserve user-owned files and changes.
- Follow the scope the owner assigns. Pending items in STATUS.md are product dependencies, not tool assignments or a prescribed work split.

## How the owner works

- Treat the owner as hands-on. Delegate effort, not judgment or accountability.
- Lead with the outcome and current evidence. Distinguish planned, built, tested, merged, released, deployed, and verified.
- Before a substantial slice, state its objective, done checks, non-goals, and constraints. Stop when the evidence passes.
- Make reasonable low-risk assumptions. Ask only when a choice changes scope, risk, cost, or the result.
- Keep updates short: what changed, what failed, and what comes next.
- Prefer the smallest complete solution. Avoid speculative features, abstractions, wrappers, hardening, and unrelated cleanup.
- A review or diagnosis does not authorize edits. An implementation request authorizes normal in-scope edits and checks.

## Architecture boundaries

- The selected stack is Rails + Hotwire + PostgreSQL for the control plane and Go for the execution runner.
- Use Rails and Ruby standard capabilities first. Rails-generated first-party/default dependencies are approved for bootstrap. Any additional production gem, Go module, JavaScript pin, service, or package needs owner approval.
- Do not introduce a Node backend, React, Vue, Svelte, Inertia, Vite, or a JavaScript/CSS dependency tree without a proven product requirement and owner approval.
- Keep browser JavaScript small, self-hosted, pinned, and tied to a specific interaction. Prefer server-rendered HTML, Turbo, and small Stimulus controllers.
- PostgreSQL is authoritative for tenant, business, security, policy, memory-record, and execution-ledger state.
- Rails must never invoke a model CLI, agent runtime, or arbitrary shell command directly. Rails submits work through the versioned runner protocol; Go owns process lifecycle and runtime isolation.
- The product domain must be provider-neutral. Register adapters and their capabilities; branch on capabilities and policies, not provider or model names.
- Implement and prove the deterministic scripted adapter before adding a live LLM or coding-agent adapter.
- Use self-hosted Supermemory behind the internal memory contract for eligible memory indexing and retrieval. Supermemory and pgvector are owner-approved architecture choices; any new implementation dependency still follows the dependency-approval rule above.
- Agents may use approved read-only public-web search, but web content is untrusted evidence and the runner does not receive general egress.
- No agent may send, schedule, or trigger a customer message in v1. A human must review or edit the draft and deliberately press Send; attribute the send to that human.

## UI work

- For meaningful interface work in Amp, use the Impeccable and Ui.sh plugins and only the Matt Pocock skills that are relevant to the current UI, testing, or review task.
- Those tools inform implementation quality; they do not authorize a TypeScript/React architecture or new production dependencies.
- Follow one coherent product language. Cover desktop and mobile layouts, keyboard use, focus, and loading, empty, error, blocked, approval, and success states.
- Visually inspect and browser-test meaningful UI changes at relevant sizes and states.

## Delivery

- Use Conventional Commits. Each commit should contain one complete, reversible concern.
- Deliver the milestone as small stacked PRs. Each PR must be reviewable, green, and based on the preceding PR; do not bundle unrelated work.
- Continue autonomously through the owner-assigned scope after each green PR. Do not wait for routine checkpoint approval.
- Stop only for a material scope, security, data, cost, destructive-action, external-credential, or unapproved-production-dependency blocker. Continue independent safe work first and batch related decisions.
- Do not create or coordinate extra implementation threads unless the owner asks. The owner will supply Amp-specific multi-threading instructions.
- Inspect branch, remote, and working-tree state before changing or pushing anything. Never discard or sweep in unrelated changes.
- Do not force-push. Do not push known-broken work or unexpectedly push to the default branch.
- Run repository-native formatting, linting, focused tests, and relevant broader checks. Do not invent duplicate tooling.
- Before handoff, perform one risk-based review and report exact checks, failures, known gaps, and the next incomplete slice.

## Documentation

- Keep the root lean. README.md and this file are entry points; durable detail belongs under documentation/.
- Update documentation only when behaviour, architecture, setup, operations, or durable decisions change.
- Remove stale guidance instead of accumulating parallel plans.
