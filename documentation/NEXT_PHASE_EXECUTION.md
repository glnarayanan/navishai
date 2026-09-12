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
| C1 Scorecard proposal | PR open | [PR #118](https://github.com/glnarayanan/navishai/pull/118) `cursor/scorecard-proposal-efe6` | Branched from verified `main` (`aa4b079`). Scripted-adapter proof. |
| C2 Proposal revision | PR open | [PR #120](https://github.com/glnarayanan/navishai/pull/120) `cursor/scorecard-revision-efe6` | Stacked on C1. Inspectable diffs, parent/run lineage, stale-tab guards. |
| C3 Preview/backtest evidence | PR open | [PR #122](https://github.com/glnarayanan/navishai/pull/122) `cursor/scorecard-preview-efe6` | Publish bound to inspected preview and 500-snapshot cap. |
| D1 Support quality readout | PR open (independent stack) | [PR #117](https://github.com/glnarayanan/navishai/pull/117) `cursor/support-quality-efe6` | Branched from verified `main` (`aa4b079`). Read-only; members and viewers included. Not merged into C. |
| D2 Knowledge improvement queue | PR open (independent stack) | [PR #119](https://github.com/glnarayanan/navishai/pull/119) `cursor/knowledge-improvements-efe6` | Stacked on D1. Stale, deleted, retired, and failed-sync sources. |
| D3 Follow-up evidence | PR open (independent stack) | [PR #121](https://github.com/glnarayanan/navishai/pull/121) `cursor/knowledge-follow-up-efe6` | Stacked on D2. New current version leaves the queue; lineage retained. |
| E1 Integrated scenario | PR open | [PR #123](https://github.com/glnarayanan/navishai/pull/123) `cursor/integrated-scenario-efe6` | Scorecard C1–C3 journey proof on the C stack. D proof stays on D3. |
| E2 Status and handoff | PR open | [PR #124](https://github.com/glnarayanan/navishai/pull/124) `cursor/phase-handoff-efe6` | Documents C and D stacks, engineering vs operational, and DEC/BLK. |

## Decisions and blockers

| ID | Slice | Type | Evidence | Impact | Recommendation | Safe continuation | Resume condition | State |
|---|---|---|---|---|---|---|---|---|
| BLK-001 | A1 | Credential/host | No live self-hosted Supermemory on this check host. | Live indexing/retrieval/removal is not operationally accepted. | Keep fixture coverage. Do not claim live engine proof. | Phase implementation is complete. | Operator-supplied self-hosted Supermemory on a disposable host. | open |
| BLK-002 | A2 | Host | `docker` is not installed. | Changed-image upgrade is not operationally accepted. | Keep production guard until live digest proof. | Phase implementation is complete. | Docker Engine + Compose v2. | open |
| BLK-003 | All stacks | Tooling | Draft PRs #111–#124 cover A1–E2. | None. Stacked GitHub PRs exist. | Keep drafts until review. | Live-host proof (BLK-001, BLK-002, BLK-004). | Owner review and merge authorization. | resolved |
| BLK-004 | A3 | Host/credential | No Docker, public DNS, ACME, signing identity, or live SMTP/scanner/provider on this host. | I5 and live connector checks remain omitted, not passing. | Keep omissions explicit. | Phase implementation is complete. | Clean supported host plus operator-owned credentials and signing identity. | open |
| DEC-001 | A1 | Routine | Owner and Admin may start the memory check, matching the setup-checklist role gate. | Broader than Owner-only if that phrase is read strictly. | Keep Owner/Admin. | Continue. | Owner restricts to Owner-only. | accepted |
| DEC-002 | A2 | Routine | App-image compatibility uses Docker-save manifests plus `db:migrate:status`; no schema-change claim. | Unsupported/indeterminate still rejected before stop. | Keep the guard. | Continue. | Owner expands the supported upgrade class. | accepted |
| DEC-003 | C1 | Durable | Scorecard AI proposals use crew-task `scope_kind=health_scorecard` and reuse `success_strategist`. No ninth agent role. | Workspace-level work is not forced onto a dummy Account. | Keep this scope. | C2–E2 completed on this decision. | Owner requires a dedicated designer role. | accepted |

## PR stack

| Branch | Base | Slice | PR | Suggested title |
|---|---|---|---|---|
| `cursor/memory-verification-efe6` | `main` | A1 | [#112](https://github.com/glnarayanan/navishai/pull/112) | feat: verify configured memory through scoped round trips |
| `cursor/app-image-upgrade-efe6` | `cursor/memory-verification-efe6` | A2 | [#114](https://github.com/glnarayanan/navishai/pull/114) | feat: support verified application image upgrades |
| `cursor/deployment-acceptance-efe6` | `cursor/app-image-upgrade-efe6` | A3 | [#115](https://github.com/glnarayanan/navishai/pull/115) | docs: record applicable installer acceptance omissions |
| `cursor/account-work-queries-efe6` | `main` | B1 | [#111](https://github.com/glnarayanan/navishai/pull/111) | feat: query account attention and renewal work |
| `cursor/retention-queue-ui-efe6` | `cursor/account-work-queries-efe6` | B2 | [#113](https://github.com/glnarayanan/navishai/pull/113) | feat: surface account work in the retention queue |
| `cursor/intervention-follow-up-efe6` | `cursor/retention-queue-ui-efe6` | B3 | [#116](https://github.com/glnarayanan/navishai/pull/116) | feat: manage intervention ownership and follow-up |
| `cursor/scorecard-proposal-efe6` | `main` | C1 | [#118](https://github.com/glnarayanan/navishai/pull/118) | feat: generate constrained scorecard proposals through the runner |
| `cursor/scorecard-revision-efe6` | `cursor/scorecard-proposal-efe6` | C2 | [#120](https://github.com/glnarayanan/navishai/pull/120) | feat: revise scorecard proposals with inspectable diffs |
| `cursor/scorecard-preview-efe6` | `cursor/scorecard-revision-efe6` | C3 | [#122](https://github.com/glnarayanan/navishai/pull/122) | feat: bind scorecard publish to the inspected preview |
| `cursor/support-quality-efe6` | `main` | D1 | [#117](https://github.com/glnarayanan/navishai/pull/117) | feat: surface a workspace support quality readout |
| `cursor/knowledge-improvements-efe6` | `cursor/support-quality-efe6` | D2 | [#119](https://github.com/glnarayanan/navishai/pull/119) | feat: queue stale and failed knowledge sources |
| `cursor/knowledge-follow-up-efe6` | `cursor/knowledge-improvements-efe6` | D3 | [#121](https://github.com/glnarayanan/navishai/pull/121) | feat: retain knowledge improvement follow-up evidence |
| `cursor/integrated-scenario-efe6` | `cursor/scorecard-preview-efe6` | E1 | [#123](https://github.com/glnarayanan/navishai/pull/123) | feat: prove the scorecard proposal publish journey |
| `cursor/phase-handoff-efe6` | `cursor/integrated-scenario-efe6` | E2 | [#124](https://github.com/glnarayanan/navishai/pull/124) | docs: record remaining-work and operator handoff |

## Engineering versus operational

| Slice | Engineering | Operational |
|---|---|---|
| A1 | Fixture-complete on [PR #112](https://github.com/glnarayanan/navishai/pull/112) | Live self-hosted Supermemory is BLK-001 |
| A2 | Fixture-complete on [PR #114](https://github.com/glnarayanan/navishai/pull/114) | Live Docker digest proof is BLK-002 |
| A3 | Evidence-only omissions on [PR #115](https://github.com/glnarayanan/navishai/pull/115) | Clean-host/ACME/signing is BLK-004 |
| B1–B3 | Fixture-complete on [PRs #111](https://github.com/glnarayanan/navishai/pull/111), [#113](https://github.com/glnarayanan/navishai/pull/113), [#116](https://github.com/glnarayanan/navishai/pull/116) | No live-host gap beyond A |
| C1–C3 | Scripted-adapter scorecard proposal, revision, and inspected-preview publish on [#118](https://github.com/glnarayanan/navishai/pull/118)–[#122](https://github.com/glnarayanan/navishai/pull/122) | Live model execution is not claimed |
| D1–D3 | Read-only Quality and knowledge Improvements on [#117](https://github.com/glnarayanan/navishai/pull/117)–[#121](https://github.com/glnarayanan/navishai/pull/121) | Does not score or send |
| E1 | Scorecard journey integration test on [#123](https://github.com/glnarayanan/navishai/pull/123) | Does not merge D |
| E2 | This handoff on [#124](https://github.com/glnarayanan/navishai/pull/124) | Next incomplete slice is live-host proof (BLK-001, BLK-002, BLK-004) |

## Operator handoff

Two independent stacks leave `main` (`aa4b079`). Do not merge C into D or D into C.

- **C stack:** `cursor/scorecard-proposal-efe6` → `cursor/scorecard-revision-efe6` → `cursor/scorecard-preview-efe6` → `cursor/integrated-scenario-efe6` → `cursor/phase-handoff-efe6`
- **D stack:** `cursor/support-quality-efe6` → `cursor/knowledge-improvements-efe6` → `cursor/knowledge-follow-up-efe6`

D proof stays on D3. C journey proof stays on E1. This E2 branch documents both.

DEC-003 is accepted: scorecard AI proposals use `scope_kind=health_scorecard` and reuse `success_strategist`. BLK-003 is resolved (draft PRs #111–#124). BLK-001, BLK-002, and BLK-004 stay open until live proof.

No merge, release, or deploy from this phase. No live Claude/Anthropic implementation review.
