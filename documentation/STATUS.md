# Rebuild status

Updated 30 September 2026. [PRODUCT.md](./PRODUCT.md) replaces the old helpdesk
milestones. The rebuild is not complete. Nothing has merged, released or deployed.

## Delivered stack

- [#141](https://github.com/glnarayanan/navishai/pull/141): product, architecture,
  domain and rebuild authorities, written before new domain code.
- [#142](https://github.com/glnarayanan/navishai/pull/142), based on #141: Phase A
  demolition. Removed 820 tracked files, about 135,000 lines, including helpdesk,
  messaging, SLAs, CS workflows, crews, Supermemory, process runner, obsolete tests,
  installers and docs. Kept auth, workspace access, audit and relevant security.
- [#143](https://github.com/glnarayanan/navishai/pull/143), based on #142: first Phase B slice. Corpus intake,
  snapshots, source evidence, pagination, email masking, retention and deletion.
- `rebuild/04-corpus-discovery`, based on #143: frozen local analysis, term clusters,
  risk-prioritised candidate selection and immutable expert taxonomy revisions.

## Built and checked

Rails/Hotwire/PostgreSQL with native jobs, local fonts and no new production
dependency. Fresh lab databases leave the old development/test databases alone.
Preflight rejects old names and old-domain tables; setup refuses reset. Local
auth, verification/reset, invitations, OIDC, first Owner, break-glass, last-Owner
locking, CSP, headers, log filters and append-only audit remain. No PostgreSQL RLS.

Bounded JSON conversation exports and text/Markdown intake retain input digest,
processing/redaction version and fixed records. Repeat uploads reuse a snapshot;
changed uploads add one. Composite foreign keys prevent foreign-workspace/corpus
links. Local term analysis and expert label revisions are built; scenarios and
evaluation execution are not built yet.
Expiry hides source content immediately; an hourly job deletes snapshots/items.
Managing roles can delete sources with typed confirmation. Audit retains no source
content. Email masking is not complete PII removal; original files are not kept.

- Phase A `bin/ci`: 120 Rails tests / 642 assertions; 2 browser tests / 49 assertions.
- Corpus `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 48.01s; RuboCop 119 files
  clean; gem/importmap audits clean; Brakeman 0 warnings/errors; eager load passes;
  129 Rails tests / 758 assertions; 3 browser tests / 66 assertions; no failures,
  errors or skips. An exact Phase A association-list test initially failed and now
  checks absence of obsolete associations without blocking new domain records.
- Intake tests cover changed/repeated versions, redaction choices and email IDs,
  both supported vendor shapes, malformed/oversize/partial batches, foreign links,
  viewers, immutable updates, escaping and deletion/expiry. Desktop/mobile source
  and error captures under `.amp/in/artifacts/corpus/` were inspected; expanded
  captures confirm both records and all recovery controls. No horizontal overflow
  or CSP violations. `git diff --check` passes.
- Direct risk-based review used; Ponytail Audit and CE Code Review are unavailable.
- Local discovery `CAPTURE_LAB_SCREENSHOTS=1 bin/ci`: passed in 53.05s; 132 Ruby files clean, audits clean,
  Brakeman zero warnings/errors, eager load passes; 134 Rails tests / 791 assertions
  and 4 browser tests / 84 assertions, no failures/errors/skips. Tests distinguish
  related company terms from unrelated families, minority critical risk from
  volume, frozen inputs from later imports, human revisions from proposals,
  duplicate jobs, expired input and revoked access. A Rails association deletion
  default initially tried to null a required corpus ID; the purge now uses explicit
  SQL deletion. Desktop/mobile taxonomy captures inspected.

## Next and limits

Next: convert selected candidates into source-backed scenarios with expert
review/versioning and controlled variants. Compiler/calibration,
generic target execution, failure inspection and regressions follow those checks.
Continuous-learning P1 follows a proved P0 loop; classifiers remain gated by labels
and economics. Fixture checks do not establish discovery quality or judge accuracy.

No real customer dataset, live model/target, SMTP/OIDC provider, training or customer
validation ran. Clean-host/Compose image/TLS/backup/restore acceptance is unverified.
Current Compose PostgreSQL tag is not digest-pinned. Database administrators can
bypass triggers; last-Owner protection is application-side. Backups need their own
retention policy. See [development](./DEVELOPMENT.md), [security](./SECURITY.md),
[deployment](./DEPLOYMENT.md) and [design](./DESIGN.md).

The user-owned Bundler checksum in Gemfile.lock remains unstaged and outside the
rebuild commits. Phase A removed obsolete gems and capped JSON below 3 after tests
proved JSON 3 incompatible with this Rails version. No new dependency was added.
