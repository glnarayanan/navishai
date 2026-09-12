# Next-phase execution record

**Status:** Working ledger for the daily operating-workspace phase  
**Updated:** 12 September 2026

This file tracks slice state for the phase. Detailed product rules stay in [PRODUCT.md](./PRODUCT.md). Implementation evidence stays in [STATUS.md](./STATUS.md). Live-host proof is separate from fixture engineering.

States: **not started**, **in progress**, **implemented**, **tested**, **PR open**, **merged**, **externally verified**, **blocked**.

## Slice state

| Slice | State | Evidence | Notes |
|---|---|---|---|
| A1 Memory verification | tested | `cursor/memory-verification-efe6` `bccf343` | Fixture-complete. Live Supermemory is BLK-001. GitHub PR blocked by BLK-003. |
| A2 Changed-image upgrade | tested | `cursor/app-image-upgrade-efe6` `baa0a96` | Fixture-complete. Live Docker digest proof is BLK-002. GitHub PR blocked by BLK-003. |
| A3 Deployment acceptance | tested | `cursor/deployment-acceptance-efe6` `bfb3f91` | Evidence-only omissions recorded. Clean-host/ACME/signing remain BLK-004. |
| B1 Portfolio queries | tested | `AccountWorkQueue` | Fixture-complete. Independent of A2; branched from `main`. GitHub PR blocked by BLK-003. |
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
| BLK-001 | A1 | Credential/host | No live self-hosted Supermemory on this check host. | Live indexing/retrieval/removal is not operationally accepted. | Keep fixture coverage. Do not claim live engine proof. | Continue A2 fixtures and independent B/C/D. | Operator-supplied self-hosted Supermemory on a disposable host. | open |
| BLK-002 | A2 | Host | `docker` is not installed. Installer fixture suite covers supported/rejected/interrupted/restore paths. | Changed-image upgrade is not operationally accepted. | Keep production guard until live digest proof. | Continue A3 evidence and independent B/C/D. | Docker Engine + Compose v2; follow `APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md` on A2. | open |
| BLK-003 | A1/A2/A3 | Tooling | ManagePullRequest is unavailable; `gh` is read-only for PR creation. Branches are pushed. | Stacked GitHub PRs are not opened. | Record exact PR metadata; continue implementation. | Continue independent stacks. | Write-capable PR tool or owner opens PRs from pushed branches. | open |
| BLK-004 | A3 | Host/credential | No Docker, public DNS, ACME, signing identity, or live SMTP/scanner/provider on this host. | I5 and live connector checks remain omitted, not passing. | Keep omissions explicit. | Continue B/C/D. | Clean supported host plus operator-owned credentials and signing identity. | open |
| DEC-001 | A1 | Routine | Owner and Admin may start the memory check, matching the setup-checklist role gate. | Broader than Owner-only if that phrase is read strictly. | Keep Owner/Admin. | Continue. | Owner restricts to Owner-only. | accepted |
| DEC-002 | A2 | Routine | App-image compatibility uses Docker-save manifests plus `db:migrate:status`; no schema-change claim. | Unsupported/indeterminate still rejected before stop. | Keep the guard for PG major, Supermemory, topology, and down migrations. | Continue. | Owner expands the supported upgrade class. | accepted |

## PR stack

Recorded for opening. GitHub PR creation is BLK-003.

| Branch | Base | Slice | Suggested title |
|---|---|---|---|
| `cursor/memory-verification-efe6` | `main` | A1 | feat: verify configured memory through scoped round trips |
| `cursor/app-image-upgrade-efe6` | `cursor/memory-verification-efe6` | A2 | feat: support verified application image upgrades |
| `cursor/deployment-acceptance-efe6` | `cursor/app-image-upgrade-efe6` | A3 | docs: record applicable installer acceptance omissions |
| `cursor/account-work-queries-efe6` | `main` | B1 | feat: query account attention and renewal work |
