# Next-phase execution record

**Status:** Working ledger for the daily operating-workspace phase  
**Updated:** 12 September 2026

This file tracks slice state for the phase. Detailed product rules stay in [PRODUCT.md](./PRODUCT.md). Implementation evidence stays in [STATUS.md](./STATUS.md). Live-host proof is separate from fixture engineering.

States: **not started**, **in progress**, **implemented**, **tested**, **PR open**, **merged**, **externally verified**, **blocked**.

## Slice state

| Slice | State | Evidence | Notes |
|---|---|---|---|
| A1 Memory verification | PR open | [PR #112](https://github.com/glnarayanan/navishai/pull/112) `cursor/memory-verification-efe6` | Fixture-complete. Live Supermemory is BLK-001. |
| A2 Changed-image upgrade | PR open | [PR #114](https://github.com/glnarayanan/navishai/pull/114) `cursor/app-image-upgrade-efe6` | Fixture-complete. Live Docker digest proof is BLK-002. |
| A3 Deployment acceptance | PR open | [PR #115](https://github.com/glnarayanan/navishai/pull/115) `cursor/deployment-acceptance-efe6` | Evidence-only omissions recorded. Clean-host/ACME/signing remain BLK-004. |
| B1 Portfolio queries | PR open | [PR #111](https://github.com/glnarayanan/navishai/pull/111) `cursor/account-work-queries-efe6` | Fixture-complete. Independent of A. |
| B2 Retention queue UI | PR open | [PR #113](https://github.com/glnarayanan/navishai/pull/113) `cursor/retention-queue-ui-efe6` | Desktop/390/320 system coverage. |
| B3 Intervention follow-up | PR open | [PR #116](https://github.com/glnarayanan/navishai/pull/116) `cursor/intervention-follow-up-efe6` | Fixture-complete. |
| C1 Scorecard proposal | tested | `cursor/scorecard-proposal-efe6` | Branched from verified `main` (`aa4b079`). Scripted-adapter proof. GitHub PR pending (BLK-003). |
| C2 Proposal revision | tested | `cursor/scorecard-revision-efe6` | Stacked on C1. Inspectable diffs, parent/run lineage, stale-tab guards. GitHub PR pending (BLK-003). |
| C3 Preview/backtest evidence | not started | — | Depends on C2. |
| D1 Support quality readout | not started | — | Starts from verified `main`. |
| D2 Knowledge improvement queue | not started | — | Depends on D1. |
| D3 Follow-up evidence | not started | — | Depends on D2. |
| E1 Integrated scenario | not started | — | After C and D feature branches. |
| E2 Status and handoff | not started | — | After E1. |

## Decisions and blockers

| ID | Slice | Type | Evidence | Impact | Recommendation | Safe continuation | Resume condition | State |
|---|---|---|---|---|---|---|---|---|
| BLK-001 | A1 | Credential/host | No live self-hosted Supermemory on this check host. | Live indexing/retrieval/removal is not operationally accepted. | Keep fixture coverage. Do not claim live engine proof. | Continue independent C/D. | Operator-supplied self-hosted Supermemory on a disposable host. | open |
| BLK-002 | A2 | Host | `docker` is not installed. | Changed-image upgrade is not operationally accepted. | Keep production guard until live digest proof. | Continue independent C/D. | Docker Engine + Compose v2. | open |
| BLK-003 | C1+ | Tooling | A1–B3 stacked PRs exist (#111–#116). ManagePullRequest is still unavailable in this agent; `gh` is read-only for PR creation. | C/D/E GitHub PRs may still need the write-capable tool or owner opening. | Record exact PR metadata when opened. | Continue implementation. | Write-capable PR tool or owner opens remaining PRs. | open for C/D/E; A1–B3 resolved |
| BLK-004 | A3 | Host/credential | No Docker, public DNS, ACME, signing identity, or live SMTP/scanner/provider on this host. | I5 and live connector checks remain omitted, not passing. | Keep omissions explicit. | Continue C/D. | Clean supported host plus operator-owned credentials and signing identity. | open |
| DEC-001 | A1 | Routine | Owner and Admin may start the memory check, matching the setup-checklist role gate. | Broader than Owner-only if that phrase is read strictly. | Keep Owner/Admin. | Continue. | Owner restricts to Owner-only. | accepted |
| DEC-002 | A2 | Routine | App-image compatibility uses Docker-save manifests plus `db:migrate:status`; no schema-change claim. | Unsupported/indeterminate still rejected before stop. | Keep the guard. | Continue. | Owner expands the supported upgrade class. | accepted |
| DEC-003 | C1 | Durable | Scorecard AI proposals use crew-task `scope_kind=health_scorecard` and reuse `success_strategist`. No ninth agent role. | Workspace-level work is not forced onto a dummy Account. | Keep this scope. | Continue C2. | Owner requires a dedicated designer role. | accepted |

## PR stack

| Branch | Base | Slice | PR | Suggested title |
|---|---|---|---|---|
| `cursor/memory-verification-efe6` | `main` | A1 | [#112](https://github.com/glnarayanan/navishai/pull/112) | feat: verify configured memory through scoped round trips |
| `cursor/app-image-upgrade-efe6` | `cursor/memory-verification-efe6` | A2 | [#114](https://github.com/glnarayanan/navishai/pull/114) | feat: support verified application image upgrades |
| `cursor/deployment-acceptance-efe6` | `cursor/app-image-upgrade-efe6` | A3 | [#115](https://github.com/glnarayanan/navishai/pull/115) | docs: record applicable installer acceptance omissions |
| `cursor/account-work-queries-efe6` | `main` | B1 | [#111](https://github.com/glnarayanan/navishai/pull/111) | feat: query account attention and renewal work |
| `cursor/retention-queue-ui-efe6` | `cursor/account-work-queries-efe6` | B2 | [#113](https://github.com/glnarayanan/navishai/pull/113) | feat: surface account work in the retention queue |
| `cursor/intervention-follow-up-efe6` | `cursor/retention-queue-ui-efe6` | B3 | [#116](https://github.com/glnarayanan/navishai/pull/116) | feat: manage intervention ownership and follow-up |
| `cursor/scorecard-proposal-efe6` | `main` | C1 | pending | feat: generate constrained scorecard proposals through the runner |
| `cursor/scorecard-revision-efe6` | `cursor/scorecard-proposal-efe6` | C2 | pending | feat: revise scorecard proposals with inspectable diffs |
