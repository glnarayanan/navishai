# Next-phase execution record

**Status:** Working ledger for the daily operating-workspace phase  
**Updated:** 12 September 2026

This file tracks slice state for the phase. Detailed product rules stay in [PRODUCT.md](./PRODUCT.md). Implementation evidence stays in [STATUS.md](./STATUS.md). Live-host proof is separate from fixture engineering.

States: **not started**, **in progress**, **implemented**, **tested**, **PR open**, **merged**, **externally verified**, **blocked**.

## Slice state

| Slice | State | Evidence | Notes |
|---|---|---|---|
| A1 Memory verification | in progress | `MemoryVerificationCheck`, checklist and reliability surfaces | Fixture engineering in progress. Live Supermemory is BLK-001. |
| A2 Changed-image upgrade | not started | Existing production guard still rejects changed images | Preserve guard until A2 has evidence. |
| A3 Deployment acceptance | not started | [INSTALLER_ACCEPTANCE_EVIDENCE.md](./INSTALLER_ACCEPTANCE_EVIDENCE.md) | Evidence-only unless A1/A2 require a new procedure. |
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
| DEC-001 | A1 | Routine | Owner and Admin may start the check, matching the existing setup-checklist role gate. Members and Viewers are denied. | Broader than the word "Owner-triggered" if read as Owner-only. | Keep Owner/Admin, consistent with scanner test and checklist access. | Continue. | Owner decides to restrict to Owner-only. | accepted |

## PR stack

Recorded as PRs open.

| Branch | Base | Slice |
|---|---|---|
| `cursor/memory-verification-efe6` | `main` | A1 |
