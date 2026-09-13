# Next-phase execution record

**Status:** Working ledger for the daily operating-workspace phase  
**Updated:** 13 September 2026

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
| B3 Intervention follow-up | PR open | [PR #116](https://github.com/glnarayanan/navishai/pull/116) `cursor/intervention-follow-up-efe6` | Fixture-complete. Merged into E1 for the full journey. |
| C1 Scorecard proposal | PR open | [PR #118](https://github.com/glnarayanan/navishai/pull/118) `cursor/scorecard-proposal-efe6` | Branched from verified `main` (`aa4b079`). Scripted-adapter proof. |
| C2 Proposal revision | PR open | [PR #120](https://github.com/glnarayanan/navishai/pull/120) `cursor/scorecard-revision-efe6` | Stacked on C1. Inspectable diffs, parent/run lineage, stale-tab guards. |
| C3 Preview/backtest evidence | PR open | [PR #122](https://github.com/glnarayanan/navishai/pull/122) `cursor/scorecard-preview-efe6` | Publish bound to inspected preview and 500-snapshot cap. |
| D1 Support quality readout | PR open | [PR #117](https://github.com/glnarayanan/navishai/pull/117) `cursor/support-quality-efe6` | Branched from verified `main` (`aa4b079`). Read-only; members and viewers included. Merged into E1. |
| D2 Knowledge improvement queue | PR open | [PR #119](https://github.com/glnarayanan/navishai/pull/119) `cursor/knowledge-improvements-efe6` | Stacked on D1. Stale, deleted, retired, and failed-sync sources. Merged into E1. |
| D3 Follow-up evidence | PR open | [PR #121](https://github.com/glnarayanan/navishai/pull/121) `cursor/knowledge-follow-up-efe6` | Stacked on D2. Assign/triage/resolve/dismiss candidates with audit. Merged into E1. |
| E1 Integrated scenario | tested | [PR #123](https://github.com/glnarayanan/navishai/pull/123) `cursor/integrated-scenario-efe6` | B3+C3+D3 merge commits plus the 14-step fixture journey and named failure variants. |
| E2 Status and handoff | in progress | `cursor/phase-handoff-efe6` | After E1. |

## Decisions and blockers

| ID | Slice | Type | Evidence | Impact | Recommendation | Safe continuation | Resume condition | State |
|---|---|---|---|---|---|---|---|---|
| BLK-001 | A1 | Credential/host | No live self-hosted Supermemory on this check host. | Live indexing/retrieval/removal is not operationally accepted. | Keep fixture coverage. Do not claim live engine proof. | Continue independent C/D. | Operator-supplied self-hosted Supermemory on a disposable host. | open |
| BLK-002 | A2 | Host | `docker` is not installed. | Changed-image upgrade is not operationally accepted. | Keep production guard until live digest proof. | Continue independent C/D. | Docker Engine + Compose v2. | open |
| BLK-003 | C1+ | Tooling | Stacked PRs #111–#124 exist as drafts. ManagePullRequest is unavailable in this agent; `gh` is read-only for PR updates. | Marking those PRs ready for review may still need the write-capable tool or the owner. | Record exact PR metadata. Do not merge to main. | Continue implementation. | Write-capable PR tool or owner marks PRs ready. | open for ready-for-review; PR creation resolved |
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
| `cursor/scorecard-proposal-efe6` | `main` | C1 | [#118](https://github.com/glnarayanan/navishai/pull/118) | feat: generate constrained scorecard proposals through the runner |
| `cursor/scorecard-revision-efe6` | `cursor/scorecard-proposal-efe6` | C2 | [#120](https://github.com/glnarayanan/navishai/pull/120) | feat: revise scorecard proposals with inspectable diffs |
| `cursor/scorecard-preview-efe6` | `cursor/scorecard-revision-efe6` | C3 | [#122](https://github.com/glnarayanan/navishai/pull/122) | feat: bind scorecard publish to the inspected preview |
| `cursor/support-quality-efe6` | `main` | D1 | [#117](https://github.com/glnarayanan/navishai/pull/117) | feat: surface a workspace support quality readout |
| `cursor/knowledge-improvements-efe6` | `cursor/support-quality-efe6` | D2 | [#119](https://github.com/glnarayanan/navishai/pull/119) | feat: queue stale and failed knowledge sources |
| `cursor/knowledge-follow-up-efe6` | `cursor/knowledge-improvements-efe6` | D3 | [#121](https://github.com/glnarayanan/navishai/pull/121) | feat: retain knowledge improvement follow-up evidence |
| `cursor/integrated-scenario-efe6` | `cursor/scorecard-preview-efe6` | E1 | [#123](https://github.com/glnarayanan/navishai/pull/123) | feat: prove the 14-step operating workspace journey |
| `cursor/phase-handoff-efe6` | `cursor/integrated-scenario-efe6` | E2 | [#124](https://github.com/glnarayanan/navishai/pull/124) | docs: record remaining-work and operator handoff |

## E1 journey coverage

`test/integration/operating_workspace_journey_test.rb` is the named fixture journey. It does not need live credentials.

Covered steps: two isolated Workspaces; Support-case and approaching-renewal ingest; blocked draft; Support quality plus a knowledge-improvement candidate; assign to a human; authorised knowledge version linked to resolution; grounded revised draft; human review and Send through a test transport; material health change on the retention queue; intervention propose/approve/complete/review; constrained scorecard generate/revise (scripted adapter); Admin preview/publish; unchanged historical assessments; empty foreign Workspace.

Failure variants in the same file: memory unavailable, runtime unavailable, stale preview, ineligible assignee, unknown send outcome, missing cost, insufficient follow-up data.

Merge strategy: on `cursor/integrated-scenario-efe6` (C3 parent), merge commits of `origin/cursor/intervention-follow-up-efe6` (B3) and `origin/cursor/knowledge-follow-up-efe6` (D3). Feature stacks B, C, and D remain independent PRs. E1 is the integration point; do not merge C into D or D into C.

Engineering vs operational: this journey is fixture-complete. Live Supermemory (BLK-001), Docker digest proof (BLK-002), and clean-host/ACME/signing (BLK-004) stay open. The production changed-image upgrade guard stays until live digest proof. Installer audits are not reopened. ManagePullRequest is unavailable here, so stacked PRs remain drafts (BLK-003).
