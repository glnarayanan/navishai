# Next-phase execution record

**Status:** Working ledger for the daily operating-workspace phase
**Updated:** 14 September 2026

This file tracks slice state for the phase. The operator handoff covering PRs #111–#124 is [OPERATING_WORKSPACE_HANDOFF.md](./OPERATING_WORKSPACE_HANDOFF.md). Detailed product rules stay in [PRODUCT.md](./PRODUCT.md). Implementation evidence stays in [STATUS.md](./STATUS.md). Live-host proof is separate from fixture engineering.

PRs #111–#124 were all merged into `main` on 13 September 2026. Current `main` is `720a6d7`. That merge is not a launch, release, deploy, or customer-validation claim. Live-host proof remains external (BLK-001, BLK-002, BLK-004), while later product work remains separately deferred.

States: **not started**, **in progress**, **implemented**, **tested**, **PR open**, **merged**, **externally verified**, **blocked**.

## Slice state

| Slice | State | Evidence | Notes |
|---|---|---|---|
| A1 Memory verification | merged | [PR #112](https://github.com/glnarayanan/navishai/pull/112) `cursor/memory-verification-efe6` | Fixture-complete. Live Supermemory is BLK-001. |
| A2 Changed-image upgrade | merged | [PR #114](https://github.com/glnarayanan/navishai/pull/114) `cursor/app-image-upgrade-efe6` | Fixture-complete. Live Docker digest proof is BLK-002. |
| A3 Deployment acceptance | merged | [PR #115](https://github.com/glnarayanan/navishai/pull/115) `cursor/deployment-acceptance-efe6` | Evidence-only omissions recorded. Clean-host/ACME/signing remain BLK-004. |
| B1 Portfolio queries | merged | [PR #111](https://github.com/glnarayanan/navishai/pull/111) `cursor/account-work-queries-efe6` | Fixture-complete. Independent of A. |
| B2 Retention queue UI | merged | [PR #113](https://github.com/glnarayanan/navishai/pull/113) `cursor/retention-queue-ui-efe6` | Desktop/390/320 system coverage. |
| B3 Intervention follow-up | merged | [PR #116](https://github.com/glnarayanan/navishai/pull/116) `cursor/intervention-follow-up-efe6` | Fixture-complete. Merged into E1 for the full journey. |
| C1 Scorecard proposal | merged | [PR #118](https://github.com/glnarayanan/navishai/pull/118) `cursor/scorecard-proposal-efe6` | Branched from verified `main` (`aa4b079`). Scripted-adapter proof. |
| C2 Proposal revision | merged | [PR #120](https://github.com/glnarayanan/navishai/pull/120) `cursor/scorecard-revision-efe6` | Stacked on C1. Inspectable diffs, parent/run lineage, stale-tab guards. |
| C3 Preview/backtest evidence | merged | [PR #122](https://github.com/glnarayanan/navishai/pull/122) `cursor/scorecard-preview-efe6` | Publish bound to inspected preview under the version lock; 500-snapshot cap. |
| D1 Support quality readout | merged | [PR #117](https://github.com/glnarayanan/navishai/pull/117) `cursor/support-quality-efe6` | Branched from verified `main` (`aa4b079`). Read-only; members and viewers included. Merged into E1. |
| D2 Knowledge improvement queue | merged | [PR #119](https://github.com/glnarayanan/navishai/pull/119) `cursor/knowledge-improvements-efe6` | Stacked on D1. Stale, deleted, retired, and failed-sync sources. Merged into E1. |
| D3 Follow-up evidence | merged | [PR #121](https://github.com/glnarayanan/navishai/pull/121) `cursor/knowledge-follow-up-efe6` | Stacked on D2. Assign/triage/resolve/dismiss candidates with audit. Merged into E1. |
| E1 Integrated scenario | merged | [PR #123](https://github.com/glnarayanan/navishai/pull/123) `cursor/integrated-scenario-efe6` | B3+C3+D3 merge commits plus the 14-step fixture journey and named failure variants. |
| E2 Status and handoff | merged | [PR #124](https://github.com/glnarayanan/navishai/pull/124) `cursor/phase-handoff-efe6` | Documents E1 coverage, engineering vs operational, and remaining BLK items. |

## Decisions and blockers

| ID | Slice | Type | Evidence | Impact | Recommendation | Safe continuation | Resume condition | State |
|---|---|---|---|---|---|---|---|---|
| BLK-001 | A1 | Credential/host | No live self-hosted Supermemory on this check host. | Live indexing/retrieval/removal is not operationally accepted. | Keep fixture coverage. Do not claim live engine proof. | Phase implementation is complete. | Operator-supplied self-hosted Supermemory on a disposable host. | open |
| BLK-002 | A2 | Host | `docker` is not installed. | Changed-image upgrade is not operationally accepted. | Keep the production changed-image upgrade guard until live digest proof. | Phase implementation is complete. | Docker Engine + Compose v2. | open |
| BLK-003 | All stacks | Tooling | PRs #111–#124 merged on 13 September 2026. Historical PR-body edits remain unavailable to this agent. | Merge-to-main is complete; this does not affect source behaviour. | Record exact merged state; do not reopen feature work for PR-body edits. | Live-host proof and later deferred slices. | Write-capable PR tool or owner updates historical PR bodies. | open for PR-body writes only |
| BLK-004 | A3 | Host/credential | No Docker, public DNS, ACME, signing identity, or live SMTP/scanner/provider on this host. | I5 and live connector checks remain omitted, not passing. | Keep omissions explicit. Do not reopen installer audits. | Phase implementation is complete. | Clean supported host plus operator-owned credentials and signing identity. | open |
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
| `cursor/knowledge-follow-up-efe6` | `cursor/knowledge-improvements-efe6` | D3 | [#121](https://github.com/glnarayanan/navishai/pull/121) | feat: assign triage resolve and dismiss knowledge improvement candidates |
| `cursor/integrated-scenario-efe6` | `cursor/scorecard-preview-efe6` | E1 | [#123](https://github.com/glnarayanan/navishai/pull/123) | feat: prove the 14-step operating workspace journey |
| `cursor/phase-handoff-efe6` | `cursor/integrated-scenario-efe6` | E2 | [#124](https://github.com/glnarayanan/navishai/pull/124) | docs: record remaining-work and operator handoff |

## E1 journey coverage

`test/integration/operating_workspace_journey_test.rb` is the named fixture journey. It does not need live credentials.

Covered steps: two isolated Workspaces; Support-case and approaching-renewal ingest; blocked draft; Support quality plus a knowledge-improvement candidate; assign to a human; authorised knowledge version linked to resolution; grounded revised draft; human review and Send through a test transport; material health change on the retention queue; intervention propose/approve/complete/review; constrained scorecard generate/revise (scripted adapter); Admin preview/publish; unchanged historical assessments; empty foreign Workspace.

Failure variants in the same file: memory unavailable, runtime unavailable, stale preview, ineligible assignee, unknown send outcome, missing cost, insufficient follow-up data.

Merge strategy: on `cursor/integrated-scenario-efe6` (C3 parent), merge commits of `origin/cursor/intervention-follow-up-efe6` (B3) and `origin/cursor/knowledge-follow-up-efe6` (D3). Feature stacks A, B, C, and D remain independent PRs. E1 is the integration point; do not merge C into D or D into C as feature stacks. This E2 branch sits on the E1 tip and therefore contains B3+C3+D3 through those merge commits.

## Engineering versus operational

| Slice | Engineering | Operational |
|---|---|---|
| A1 | Fixture-complete on [PR #112](https://github.com/glnarayanan/navishai/pull/112) | Live self-hosted Supermemory is BLK-001 |
| A2 | Fixture-complete on [PR #114](https://github.com/glnarayanan/navishai/pull/114) | Live Docker digest proof is BLK-002. Production changed-image upgrade stays guarded. |
| A3 | Evidence-only omissions on [PR #115](https://github.com/glnarayanan/navishai/pull/115) | Clean-host/ACME/signing is BLK-004. Installer audits are not reopened. |
| B1–B3 | Fixture-complete on [PRs #111](https://github.com/glnarayanan/navishai/pull/111), [#113](https://github.com/glnarayanan/navishai/pull/113), [#116](https://github.com/glnarayanan/navishai/pull/116) | No live-host gap beyond A |
| C1–C3 | Scripted-adapter scorecard proposal, revision, and inspected-preview publish on [#118](https://github.com/glnarayanan/navishai/pull/118)–[#122](https://github.com/glnarayanan/navishai/pull/122) | Live model execution is not claimed |
| D1–D3 | Quality readout, stale-source queue, and assign/triage/resolve/dismiss candidates on [#117](https://github.com/glnarayanan/navishai/pull/117)–[#121](https://github.com/glnarayanan/navishai/pull/121) | Does not score Accounts or send messages |
| E1 | 14-step fixture journey plus seven failure variants on [#123](https://github.com/glnarayanan/navishai/pull/123) | No live credentials. CI fixes cherry-picked; the green `bin/ci` record is on E2 |
| E2 | Dedicated operator handoff on [#124](https://github.com/glnarayanan/navishai/pull/124) | Historical `bin/ci` passed at `fdd3145`; it predates the correction top. Docker Engine was not installed and PostgreSQL on that CI host was 15.19, not pinned 16. PRs #111–#124 are merged. |

## Operator handoff

See [OPERATING_WORKSPACE_HANDOFF.md](./OPERATING_WORKSPACE_HANDOFF.md). #124 is the historical C/E integration record; A and all remaining phase PRs are also merged into `main`.

Four independent feature stacks leave `main` (`aa4b079`). Do not merge C into D or D into C.

- **A stack:** `cursor/memory-verification-efe6` → `cursor/app-image-upgrade-efe6` → `cursor/deployment-acceptance-efe6`
- **B stack:** `cursor/account-work-queries-efe6` → `cursor/retention-queue-ui-efe6` → `cursor/intervention-follow-up-efe6`
- **C stack:** `cursor/scorecard-proposal-efe6` → `cursor/scorecard-revision-efe6` → `cursor/scorecard-preview-efe6`
- **D stack:** `cursor/support-quality-efe6` → `cursor/knowledge-improvements-efe6` → `cursor/knowledge-follow-up-efe6`
- **E integration:** `cursor/integrated-scenario-efe6` (C3 + merge commits of B3 and D3) → `cursor/phase-handoff-efe6`

DEC-001, DEC-002, and DEC-003 are accepted. BLK-001, BLK-002, and BLK-004 stay open until live proof. Do not claim live Supermemory, Docker digest, or public ACME. Docker Engine was not installed. PostgreSQL on the CI host was 15.19, not pinned 16.

PRs #111–#124 are merged. This phase is not launched, released, deployed, or customer-validated. No live Claude/Anthropic implementation review.

## Post-merge correction pass

The active correction branch starts from `main` `720a6d7` and contains three feature commits: current scorecard coverage (C3), grounded support-quality evidence (D1), and post-resolution knowledge follow-up association (D3). It passed the changed-surface Rails suite on temporary local PostgreSQL 17 + pgvector (46 runs, 390 assertions, no failures, errors, or skips), full RuboCop (667 files, no offenses), Brakeman (0 warnings), and `git diff --check`. It is engineered source proof, not a new release, deployment, or live-host proof.

Full `bin/ci` is not current or green for this correction top. A broader Rails run reached 1,192 tests but needs GNU `sha256sum` and `flock` and hit BSD `script` and binary-fixture I/O incompatibilities. A system run attempted 88 tests but Chrome session creation failed. The earlier E2 `bin/ci` evidence therefore remains historical only.

## Later deferred product work

The operational blockers do not preclude separately scoped product work. Deferred work includes B2 record-specific anchors, C2 manual proposal editing, and D2 broad semantic/grouping model work. These are not included in the merged A1–E2 phase or the correction pass.
