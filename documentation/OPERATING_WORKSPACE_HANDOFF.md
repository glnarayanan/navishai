# Operating-workspace phase handoff

**Status:** Operator record for PRs #111–#124  
**Updated:** 13 September 2026  
**Phase state:** Fixture-complete. Not launched, released, deployed, or customer-validated.

This is the durable operator handoff. Slice-state bookkeeping stays in [NEXT_PHASE_EXECUTION.md](./NEXT_PHASE_EXECUTION.md). Product rules stay in [PRODUCT.md](./PRODUCT.md). Evidence stays in [STATUS.md](./STATUS.md).

**#124 (`cursor/phase-handoff-efe6`) is the latest integrated product tip.** It contains B+C+D+E work through E1 merge commits. It does **not** contain the A installer/memory/upgrade stack. A is a parallel stack and still needs its own merge commits into `main`.

Owner authorized merge-commit integration into `main` on 13 September 2026 (merge commits only; no squash, no rebase). That authorization is not a launch, release, deploy, or customer-validation claim.

**Next incomplete slice:** live-host proof (BLK-001, BLK-002, BLK-004). Not more feature work.

## Stack diagram

```
origin/main  aa4b079  chore: enable orb development portal

A  (parallel; not in #124)
  #112 cursor/memory-verification-efe6     ← main
  #114 cursor/app-image-upgrade-efe6       ← #112
  #115 cursor/deployment-acceptance-efe6   ← #114

B  (feature commits in #124 via E1; branch tips still independent)
  #111 cursor/account-work-queries-efe6    ← main
  #113 cursor/retention-queue-ui-efe6      ← #111
  #116 cursor/intervention-follow-up-efe6  ← #113

C  (first-parent of E1)
  #118 cursor/scorecard-proposal-efe6      ← main
  #120 cursor/scorecard-revision-efe6      ← #118
  #122 cursor/scorecard-preview-efe6       ← #120

D  (feature commits in #124 via E1; branch tips still independent)
  #117 cursor/support-quality-efe6         ← main
  #119 cursor/knowledge-improvements-efe6  ← #117
  #121 cursor/knowledge-follow-up-efe6     ← #119

E  (integration tip)
  #123 cursor/integrated-scenario-efe6     ← #122 C3
         merge --no-ff B3 feature  9c78319
         merge --no-ff D3 feature  fc8d15d
  #124 cursor/phase-handoff-efe6           ← #123   ← latest B+C+D+E tip
```

Do not merge C into D or D into C as feature stacks. E1 is the only integration point for B+C+D.

## E1 merge strategy

E1 (`cursor/integrated-scenario-efe6`) started from C3. It then used **merge commits, not rebase**, to bring in the B3 and D3 feature histories:

| Merge commit | Parents | What it brought |
|---|---|---|
| `9c783194b9af` | C-side `f341503` + B3 feature `9caa1996d119` | Intervention follow-up |
| `fc8d15d1faff` | E1 after B3 + D3 feature `1e2dc98d4c41` | Knowledge follow-up |

Later LibreOffice `OpenFiles`/`Processes` 512-limit commits were cherry-picked onto each stack tip independently, so those **tip SHAs are not shared ancestors**. The product feature commits are in #124; the A-stack tips are not.

## Decisions and blockers

| ID | State | Note |
|---|---|---|
| DEC-001 | accepted | Owner and Admin may start the memory verification check (same gate as the scanner/checklist). |
| DEC-002 | accepted | Changed-image upgrade compatibility uses Docker-save manifests plus `db:migrate:status`. No schema-change claim. Unsupported targets stay rejected. |
| DEC-003 | accepted | Scorecard AI proposals use crew-task `scope_kind=health_scorecard` and reuse `success_strategist`. No ninth agent role. |
| BLK-001 | open | Live self-hosted Supermemory indexing/retrieval/removal is not proved. |
| BLK-002 | open | Live application-image digest upgrade is not proved. Docker Engine was not installed on the check host. Do not claim Docker-green. |
| BLK-004 | open | Clean supported-host I5, public ACME, reboot/SSH interruption, and release signing remain omitted. |
| BLK-003 | open (PR bodies only) | ManagePullRequest was unavailable. Owner later authorized merge-commit integration into `main`. |

Check-host notes that are **not** production pins: PostgreSQL **15.19** (documented `PG_MAJOR=15` override vs pinned 16); Docker Engine absent.

## Checks

| Where | SHA | Result |
|---|---|---|
| E2 green `bin/ci` | `fdd31456a20f` | Full `bin/ci` exit 0 in 4m38.72s. Rails 1162/8494, system 87/1414. Isolation required. Docs note `b9e0a80536c0`. Docker omitted. |
| C tip `bin/ci` | `f4cb1a9c756a` | Full `bin/ci` exit 0 in 3m58.69s, including Brakeman, `TestInstalledLibreOffice`, legacy Word conversion. Docker omitted. |
| D tip `bin/ci` | `81751bdd3761` | Full `bin/ci` exit 0 in 4m56.94s, including Brakeman and legacy Word conversion. Docker omitted. |
| A isolation after 512-limit | `bb933d95aefe` | Isolation subset / `TestInstalledLibreOffice` after raising LibreOffice `OpenFiles: 512`, `Processes: 512`. Docker omitted. Same converter change landed independently on E2 as `fdd31456a20f`. |

PostgreSQL on the CI host was **15.19**, not pinned 16. Docker Engine was **not** installed; Compose and image paths stay omitted and are not recorded as passing.

## Pull requests

Engineering = fixture/source complete. Operational = live-host proof.

### A stack (parallel; merge into main separately)

**#112** `cursor/memory-verification-efe6` ← `main` — **engineering.** Owners/Admins start a scoped memory round trip (index, in-Workspace retrieve, cross-Workspace deny, tombstone) bound to a non-secret configuration fingerprint. Key SHAs: `bccf34361099` (feat), `bb933d95aefe` (LibreOffice 512; isolation after this SHA). Operational: BLK-001 live Supermemory.

**#114** `cursor/app-image-upgrade-efe6` ← #112 — **engineering.** Narrow changed-application-image `upgrade` when Docker-save identity, Compose topology, infra pins, PostgreSQL major, and `db:migrate:status` match. Opaque/schema/runner/memory targets still rejected. Key SHAs: `baa0a96aa4b5` (feat), `31640c308830` (512-limit), `27d39088a872` (merge-forward of A1 `bb933d9`). Operational: BLK-002 live digest on a Docker host.

**#115** `cursor/deployment-acceptance-efe6` ← #114 — **engineering (evidence-only).** Records applicable I0–I5 checks and omissions; does not mark omitted live checks as passing. Key SHAs: `bfb3f91e7974` (docs), `d359f48ee253` (merge-forward of A2). Operational: BLK-004 clean-host/ACME/signing.

### B stack (in #124 via E1)

**#111** `cursor/account-work-queries-efe6` ← `main` — **engineering.** Deterministic Account portfolio views from authoritative records (needs attention, renewal approaching, interventions awaiting approval/overdue/outcome review). No persisted AI priority score. Key SHAs: `29d1a20b8d4a` (feat), `ad5149aae8e6` (Brakeman bind), `305d98cf6fdd` (512-limit tip). Operational: no extra live-host gap beyond A.

**#113** `cursor/retention-queue-ui-efe6` ← #111 — **engineering.** Fixed filters, shareable `view` URL, counts, empty/partial/failure states; desktop/390/320 coverage. Key SHAs: `071ad443ab76` (feat), `e1717057a3b8` (test class), `54ff6ed077a9` (Brakeman), `6c05e6a1ec02` (512-limit tip).

**#116** `cursor/intervention-follow-up-efe6` ← #113 — **engineering.** Manager+ reassign/reschedule with audit; due/overdue notices to the current assignee only; jobs never send to a customer. Key SHAs: `9caa1996d119` (feat; merged into E1), `1a7812775167` (Brakeman), `3d50724cbb59` (audit truncate), `1f53743ad6cb` (512-limit tip). Focused: 22/217 workflow tests; 2/46 system tests.

### C stack (first-parent of #124)

**#118** `cursor/scorecard-proposal-efe6` ← `main` — **engineering.** Runner-backed constrained scorecard proposal (DEC-003). Generate does not publish. Scripted adapter only. Key SHAs: `2282798` (feat), `a8ddac9ac9b0` (512-limit tip). Operational: live model execution is not claimed.

**#120** `cursor/scorecard-revision-efe6` ← #118 — **engineering.** Traceable revision with parent/run lineage and inspectable diffs; stale-tab guards. Key SHAs: `9085ace177a9` (feat), `922e3dfdbd72` (merge-forward of C1).

**#122** `cursor/scorecard-preview-efe6` ← #120 — **engineering.** Publish/rollback bound to the inspected preview under the version lock; 500-snapshot cap. Key SHAs: `7e6617c27daa` (feat), `3f7bd5194a97` / `3c240323e0dd` (lock + race), `f4cb1a9c756a` (tip; green `bin/ci`).

### D stack (in #124 via E1)

**#117** `cursor/support-quality-efe6` ← `main` — **engineering.** Read-only Quality readout (SLA clocks, reopen/unproofed evidence, blocked drafts). Does not score Accounts or send. Key SHAs: `54c02a1264aa` (feat), `60b161693cc0` (512-limit tip).

**#119** `cursor/knowledge-improvements-efe6` ← #117 — **engineering.** Queue of stale, deleted, retired, and failed-sync knowledge sources. Key SHAs: `1f7746587554` (feat), `e0b889815a45` (merge-forward of D1).

**#121** `cursor/knowledge-follow-up-efe6` ← #119 — **engineering.** Assign/triage/resolve/dismiss candidates with audit; current authorised version leaves the queue. Key SHAs: `3f1052211fee` / `1e2dc98d4c41` (feat; merged into E1), `08d51fb99739` (docs), `81751bdd3761` (tip; green `bin/ci`).

### E stack (integration)

**#123** `cursor/integrated-scenario-efe6` ← #122 — **engineering.** Merge commits of B3 and D3 onto C3, then `test/integration/operating_workspace_journey_test.rb`: 14-step isolated journey plus seven failure variants. No live credentials. Key SHAs: `9c783194b9af` / `fc8d15d1faff` (merges), `283c40c9f44c` (journey), `8dbc16ef8252` (duplicate index after stack merge), `8c38c725e2e0` (512-limit tip). Focused: 8/59 journey; 45/386 related B/C/D. Full `bin/ci` recorded on E2, not this SHA.

**#124** `cursor/phase-handoff-efe6` ← #123 — **engineering (docs + CI follow-ups).** Remaining-work ledger, inspected-preview lock cherry-pick, Brakeman bind, audit truncate, LibreOffice 512-limit, green `bin/ci` at `fdd31456a20f`, docs checkpoint `b9e0a80536c0`, and this handoff. Operational: still not launched, released, deployed, or customer-validated.

## Merge into main (owner-authorized)

Use **merge commits only**. Order that preserves stack ancestry:

1. A: #112 → #114 → #115
2. C/E: #118 → #120 → #122 → #123 → #124 (this last push includes this handoff)
3. If GitHub still shows them open after #124: B #111 → #113 → #116 and D #117 → #119 → #121. Those commits may already be contained; merge commits may be empty-or-already-contained. Do not invent feature commits.

This phase remains unreleased after those merges. Resume on a disposable host for BLK-001, BLK-002, and BLK-004.
