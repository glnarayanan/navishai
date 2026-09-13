# Next-phase execution record

**Status:** Working ledger for the daily operating-workspace phase  
**Updated:** 12 September 2026

This file tracks slice state for the phase. Detailed product rules stay in [PRODUCT.md](./PRODUCT.md). Implementation evidence stays in [STATUS.md](./STATUS.md). Live-host proof is separate from fixture engineering.

States: **not started**, **in progress**, **implemented**, **tested**, **PR open**, **merged**, **externally verified**, **blocked**.

## Slice state

| Slice | State | Evidence | Notes |
|---|---|---|---|
| A1 Memory verification | tested | `MemoryVerificationCheck`, checklist and reliability surfaces, `bccf343` | Fixture engineering complete. Live Supermemory is BLK-001. PR publication blocked (no ManagePullRequest). |
| A2 Changed-image upgrade | tested | `ops/installer/navishai`, `test/scripts/installer_test.rb`, [APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md](./APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md) | Fixture engineering complete. Live digest proof is BLK-002. Opaque/unsupported targets still rejected. |
| A3 Deployment acceptance | in progress | [INSTALLER_ACCEPTANCE_EVIDENCE.md](./INSTALLER_ACCEPTANCE_EVIDENCE.md) | This check host has no Docker daemon. Record applicable omissions; do not invent live results. |
| B1 Portfolio queries | not started | — | Starts from verified `main`. |
| B2 Retention queue UI | not started | — | Depends on B1. |
| B3 Intervention follow-up | not started | — | Depends on B2. |
| C1 Scorecard proposal | not started | — | Starts from verified `main`. |
| C2 Proposal revision | not started | — | Depends on C1. |
| C3 Preview/backtest evidence | not started | — | Depends on C2. |
| D1 Support quality readout | not started | — | Starts from verified `main`. |
| D2 Knowledge improvement queue | not started | — | Depends on D1. |
| D3 Follow-up evidence | not started | — | Depends on D2. |
| E1 Integrated scenario | not started | — | After accepted feature branches. |
| E2 Status and handoff | not started | — | After E1. |

## Decisions and blockers

| ID | Slice | Type | Evidence | Impact | Recommendation | Safe continuation | Resume condition | State |
|---|---|---|---|---|---|---|---|---|
| BLK-001 | A1 | Credential/host | No live self-hosted Supermemory is available on this check host. Fixture adapter covers success, timeout, config change, cross-Workspace, incomplete cleanup, pending, and failure. | Live indexing/retrieval/removal is not operationally accepted. | Keep fixture coverage and the configuration-bound checklist result. Do not claim live engine proof. | Continue A2 fixture work and independent B/C/D stacks. | Operator-supplied self-hosted Supermemory with a non-managed key on a disposable host. | open |
| BLK-002 | A2 | Credential/host | `docker info` failed on this check host. Native installer tests (92 runs) cover identical-archive upgrades plus changed application-image success, rollback, unrecoverable restore, interrupted resume, schema/topology/runner rejection, and the opaque-archive guard. | Live old/new image digest proof, attachment retention on a real volume, and injected Compose health failure are not operationally accepted. | Keep the production guard for unsupported targets. Run [APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md](./APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md) on a disposable Docker host. | Continue A3 as evidence-only. Start B/C/D from `main`, not from this branch. | Disposable x86-64 host with Docker Engine and Compose v2; old and new Rails image ids recorded. | open |
| BLK-003 | A1/A2 | Publication | ManagePullRequest is unavailable; `gh` is read-only for writes. Branches are pushed. | GitHub PRs are not opened from this worker. | Keep local commits and exact PR metadata. Open stacked PRs when the tool is available. | Continue implementation. | ManagePullRequest or equivalent write access. | open |
| DEC-001 | A1 | Routine | Owner and Admin may start the check, matching the existing setup-checklist role gate. Members and Viewers are denied. | Broader than the word "Owner-triggered" if read as Owner-only. | Keep Owner/Admin, consistent with scanner test and checklist access. | Continue. | Owner decides to restrict to Owner-only. | accepted |
| DEC-002 | A2 | Routine | Application-image compatibility is proven from Docker-save `manifest.json` config digests plus Compose topology/infra refs and `db:migrate:status`. Schema-changing targets stay unsupported. | Does not claim general schema-change compatibility. | Keep migrate-status as the schema gate; do not add structure.sql to the candidate payload in this slice. | Continue. | Owner asks for a signed compatibility manifest in the bundle. | accepted |

## PR stack

Pushed branches. GitHub PR creation is BLK-003.

| Branch | Base | Slice |
|---|---|---|
| `cursor/memory-verification-efe6` | `main` | A1 |
| `cursor/app-image-upgrade-efe6` | `cursor/memory-verification-efe6` | A2 |
