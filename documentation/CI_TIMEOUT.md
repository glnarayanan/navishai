# Rails CI timeout investigation

1 October 2026. **A local PostgreSQL query stall is verified and fixed. Its
attribution to the historical #187 timeout remains conditional.** The fix changes
the frozen-membership read query, not fixtures, assertions, worker counts,
workflow timeouts or infrastructure. No remote run was cancelled or rerun.

## Exact scope and remote evidence

The delivery base is
[`a6b3cc0`](https://github.com/glnarayanan/navishai/commit/a6b3cc095a86a1e84a58acb743745559670c7666),
`origin/rebuild/67-bounded-mined-labels`, not the obsolete product on `main`.
A separate worktree preserved the original checkout and its owner-owned lockfile
edit. The pinned Ruby 4.0.6 and existing locked JSON 2.21.2 ran these checks;
no dependency or lockfile change belongs to this investigation.

[#187's run 36875739393](https://github.com/glnarayanan/navishai/actions/runs/36875739393)
started at 14:21:50 UTC. Its Rails job ended at 20:22:22 UTC. The check annotation
states: `The job has exceeded the maximum execution time of 6h0m0s`.
The completed log records:

- Checkout of PR merge
  [`e9fe50d`](https://github.com/glnarayanan/navishai/commit/e9fe50d3e4b12e21dffb7f6639e59010d8f5ee32),
  merging head
  [`2d011ec`](https://github.com/glnarayanan/navishai/commit/2d011ec75b18cf01527b301ce32506d22cde8f31)
  onto
  [`b12011d`](https://github.com/glnarayanan/navishai/commit/b12011dab225763a97a3f422b7e72364634d644d).
  GitHub's run metadata reports the PR head, not the checked-out merge commit.
- Ubuntu 24.04 image `20260920.314.1`, Ruby 4.0.6 revision `03b6d3f889`,
  PostgreSQL 16, Rails 8.1.3.1 and Minitest 6.0.6.
- Setup, style, gem/importmap audits, Brakeman and eager loading passed.
- `bin/rails test` at 14:23:08 UTC; `Running 419 tests in parallel using 4
  processes` at 14:23:10; `Run options: --seed 44664` at 14:23:13.
- Progress and a break-glass task's output at 14:23:48; then cancellation at
  20:22:20. No assertion failure, result summary, current-test name, thread dump,
  blocked-query snapshot or resource measurement identifies the stalled work.

The later green runs retained four Rails processes:

| PR / run | Rails seed | Rails result | Rails CI step |
|---|---:|---|---|
| [#190 / 36884566317](https://github.com/glnarayanan/navishai/actions/runs/36884566317) | 61804 | 424 tests / 5634 assertions; no failures, errors or skips | 10m20.80s |
| [#195 / 36893661157](https://github.com/glnarayanan/navishai/actions/runs/36893661157) | 35230 | 444 / 6220; no failures, errors or skips | 8m10.41s |
| [#199 / 36900053482](https://github.com/glnarayanan/navishai/actions/runs/36900053482) | 4390 | 450 / 6596; no failures, errors or skips | 12m42.89s |

The failed run contains 2149 `role "root" does not exist` lines. The three green
logs also contain them: 80, 68 and 102, respectively. The workflow's container
healthcheck runs `pg_isready` without a role. These errors do not distinguish the
timeout from a passing run and do not verify its cause. SQL constraint/immutability
errors also occur during tests that deliberately exercise database rejection;
their presence alone is not a failed assertion. The old #155/#158 browser failures
are separate; #187 did not reach its browser step.

## Harness and subprocess checks

`test/test_helper.rb` chooses at most four process workers and loads all fixtures.
Rails' `PARALLEL_WORKERS` override was set to four for the lab checks. The helper,
`config/database.yml`, `config/ci.rb` and workflow match between the failed checkout
and delivery base.

The workflow supplies an explicit `DATABASE_URL` ending in `navishai_lab_test`.
Rails disconnects its pools before forking and adds `_0` through `_3` to each
worker's effective database configuration. Lab `pg_stat_activity` snapshots
confirmed four distinct worker databases, not four writers sharing the base.
Rails does not rewrite the environment URL: a separately booted Rails subprocess
resolves the original URL. Every such lab URL named a disposable database.

The inspected native paths are:

- `test/config/production_environment_test.rb`: three `Open3.capture2e` Rails
  runner boots, covering SMTP configuration, unavailable delivery and Host checks.
- `test/services/database_preflight_test.rb`: a schema-load subprocess that
  rejects the obsolete database name before connection.
- `test/services/production_configuration_test.rb`: credential-equality refusal
  and a Rails runtime-grant task that refuses the test environment before writes.
- Delivery tests for evaluation, judges, scenario proposals and model/batch
  discovery: connection-pool threads, queues and row-lock checks.
- `test/services/http_target_transport_test.rb` and
  `test/services/system_mail_configuration_test.rb`: synthetic loopback TLS/SMTP.

Some subprocess, queue and thread-completion waits have no deadline. Rails'
process executor also waits for workers before printing Minitest's final summary.
That explains why a stuck worker *could* hide a summary, but it does not show that
one of these waits caused #187. Lab runs exercised them without a stuck wait.
No check or assertion was removed.

## Verified query cause, not a fixture-only defect

A fresh loopback-TCP replay of the **actual failed merge**, four workers and seed
44664, returned 418 of 419 test results before its 900-second lab cap (exit 124,
no summary). PostgreSQL kept one COUNT active for over twelve minutes. The backend
used CPU, had no wait event and had no blocking PID. The query was:

```sql
SELECT COUNT(*) FROM corpus_items
INNER JOIN corpus_analysis_inputs
  ON corpus_items.id = corpus_analysis_inputs.corpus_item_id
WHERE corpus_analysis_inputs.corpus_analysis_id = $1;
```

This is `CorpusAnalysis.load_inputs`'s `inputs.count.between?(1, limit)`, reached
through `fixed_inputs` during the 100,000-record streaming test. Its byte aggregate
uses the same membership join. The tables had `reltuples = 0`, with 5559 retained
pages for items and 835 for inputs. EXPLAIN estimated one row on each side and
chose an unparameterized nested loop: full index scans with a **Join Filter**, not
an inner index condition using the outer item ID. With 100,000 rows on both sides,
that plan can compare ten billion pairs.

Rails 8.1 fixture reset uses DELETE, not TRUNCATE. DELETE and native source purge
can leave allocated pages after removing rows. Autovacuum cannot analyze another
session's uncommitted fixture inserts. A seed fixes order, not worker assignment,
fixture transitions, table history or the time of an automatic statistics refresh.

The committed application path also reproduces it; it is not safe to solve this
only by analyzing large fixtures:

1. Native JSONL intake of 200 synthetic records, native analysis request, then
   native `SourcePurge.call`; commit each operation.
2. ANALYZE the now-empty item and membership tables. This models a statistics
   refresh after deletion; it does not fabricate row estimates. Both have zero
   tuples, but four and two pages remain.
3. Native JSONL intake of 20,000 records and native analysis request; commit both.
4. Confirm `open_transactions == 0`, exact item/membership counts of 20,000 and
   still-zero statistics. Run the frozen-membership COUNT under a one-second
   diagnostic statement deadline.

The original COUNT hits `PG::QueryCanceled` with the same nested-loop Join Filter.
A control on never-used empty tables (zero pages) chooses a hash join and returns
the exact count/byte sum in 0.029s. After refreshing the populated tables' statistics,
the earlier transactional control returns the exact count in 0.0104s. These changes
isolate stale empty-table statistics from a blocked child process or lock.

A plain ID subquery, added tenant predicates and GROUP BY still permit the bad
join plan. An ARRAY subquery also timed out. Correlated EXISTS with `OFFSET 0`
keeps the membership lookup as an indexed subplan instead of allowing PostgreSQL
to pull it into that join. The native committed count/byte sum then returns in
0.182s under load, while the ordinary ID subquery still times out on the same data.

## Source-query fix and regression

`CorpusAnalysis#corpus_items` now returns a lazy `CorpusItem` relation scoped to
the analysis workspace and corpus, with a correlated membership EXISTS check:

```sql
SELECT corpus_items.* FROM corpus_items
WHERE workspace_id = :workspace_id AND corpus_id = :corpus_id
  AND EXISTS (SELECT 1 FROM corpus_analysis_inputs
    WHERE corpus_analysis_id = :analysis_id
      AND corpus_item_id = corpus_items.id OFFSET 0);
```

This replaces the through-association query at its source. Repository callers
only chain reads on it; membership writes still use `CorpusAnalysisInput`.
No caller preloads this association or uses it as another association's through
path. The existing composite membership index supplies both the analysis and item
index conditions, even with zero statistics. No new index or grant is needed.

The fix must cover the shared query, not only COUNT: the minimized regression also
stalls in `expired?` before COUNT when no source has expired. The relation serves
expiry, staleness, aggregate bounds, scalar discovery batches and historical mining.
It still follows fixed membership rather than current snapshots. Tenant-scoped SQL
foreign keys, immutable inputs, expiry/purge, disclosure, resource bounds and the
existing runtime SELECT grants remain in force. No receipt or lifecycle is added.
An isolated NOLOGIN, non-superuser lab role with only schema USAGE and SELECT on
items/inputs also returned the exact 20,000 count and 988,890 retained bytes. This
checks the query's grant needs, not execution of the production grant task.

`test/services/corpus_analysis_query_test.rb` drives native intake/request/purge
within an isolated fixture transaction. It leaves empty statistics deliberately,
then imports 20,000 records without refreshing them. The five-second statement
deadline makes the old query fail rather than allowing a six-hour hang. It asserts
exact fixed selection/order, foreign-ID exclusion, replacement-snapshot exclusion,
and both sides of complete-set count and byte bounds. Expected bytes come from the
synthetic fields, not the application aggregate.

- Before source fix: one test, two assertions, one error (`PG::QueryCanceled` in
  `CorpusAnalysis#expired?`); 15.426s.
- After source fix: one test, nine assertions, no failures/errors/skips; 9.964s,
  with the same seed and four-worker harness.
- The separate committed native replay also passes `fixed_inputs(item_ids: [])`
  under a five-second deadline without a post-import ANALYZE.

## Bounded lab evidence

All data was synthetic. No real database, provider or credential was used. The
orb ran Debian 12, Linux 6.1.158, Ruby 4.0.6 at the same revision, PostgreSQL
16.15, the locked gems and four Rails workers. It is not the GitHub runner image.

| Checkout / connection | Command | Result |
|---|---|---|
| Exact delivery base / Unix socket | `bin/rails test --seed 44664 --verbose`, 900-second cap | 475 tests / 7296 assertions, no failures/errors/skips; 780.038164s |
| Exact failed merge / Unix socket | Same command/cap, temporary per-test thread dumps | 419 / 5254, no failures/errors/skips; 653.127698s |
| Exact failed merge / dedicated loopback TCP PostgreSQL | Models, config and native service tests, seed 44664, 600-second cap | 155 / 1280, no failures/errors/skips; 55.104395s |
| Exact failed merge / fresh loopback TCP PostgreSQL | Full Rails, seed 44664, 900-second cap | 418 of 419 returned; COUNT active over twelve minutes; exit 124, no summary |
| Delivery base plus source fix / fresh loopback TCP PostgreSQL | Full Rails, seed 44664, four workers, 1200-second cap | 476 / 7305, no failures/errors/skips; 652.805101s |

The fixed full run includes both 100,000-record proofs, native subprocess and
concurrency tests, tenant/SQL lineage, immutable-definition rejection and
expiry/purge coverage. Its statements kept progressing; sampled query ages stayed
below a second, with no blocking PIDs. Both large discovery/mining tests returned
(619.46s and 644.62s). `bin/rubocop` inspected 303 files with no offenses;
`bin/rails zeitwerk:check` passed, with its usual mailer-preview warning. The
repository has no separate static type-check command.

The first two full runs overlapped. Their final long tests kept issuing SQL batches;
sampled query ages were below a second and `pg_blocking_pids` returned empty arrays.
The diagnostic run's final scale test returned after 410.32s. Its thread snapshots
showed the SQL-reading path, not a stalled subprocess or queue. These observations
explain those local waits only; they are not evidence about the remote worker.

An earlier 155-test TCP probe overlapped both full runs and reached a deliberately
short 180-second cap after 132 test results. Exit 124 and SIGTERM stacks in bcrypt
and PostgreSQL record an incomplete check, not a pass or a reproduction of the
six-hour remote stall. The bounded repeat above completed. No timeout was hidden.

For a fresh replay, first start an owned, disposable PostgreSQL 16 instance on
loopback port 55433. Do not run this against an existing or real database. Choose
a new name and let `createdb` fail if it exists:

```sh
set -eu
lab="ci_timeout_repro_$(date -u +%Y%m%d%H%M%S)_lab_test"
createdb -h 127.0.0.1 -p 55433 -U postgres "$lab"
export DATABASE_URL="postgres://postgres@127.0.0.1:55433/$lab"
export RAILS_ENV=test CI=true PARALLEL_WORKERS=4 BUNDLE_FROZEN=true
bin/rails db:prepare
timeout --kill-after=10s 90s bin/rails test test/services/corpus_analysis_query_test.rb --seed 44664
timeout --kill-after=10s 1200s bin/rails test --seed 44664 --verbose
```

Check the exit status and summary. A seed fixes test ordering, not worker scheduling.
To inspect a slow replay, collect only that lab's process/thread state and database
waits. Keep credentials and source/output values out of diagnostics. Afterwards,
drop only the generated base and its four worker databases and stop the lab server.

For the **committed native** comparison, create another fresh disposable base with
the naming/setup commands above, but skip the test commands. Then run this on the
exact base and the fix, each with its own fresh database:

```sh
timeout --kill-after=10s 90s bin/rails runner - <<'RUBY'
require "stringio"
connection = ApplicationRecord.connection
raise "Disposable lab only" unless connection.pool.db_config.database.match?(/\Aci_timeout_repro_\d+_lab_test\z/)
raise "No fixture transaction" unless connection.open_transactions.zero?
user = User.create!(email_address: "planner@example.test", password: "synthetic-password", verified_at: Time.current)
organization = Organization.create!(name: "Disposable planner", slug: "planner")
workspace = organization.workspaces.create!(name: "Disposable planner", slug: "planner")
membership = workspace.memberships.create!(user:, role: "owner")
corpus = workspace.corpora.create!(name: "Disposable native intake")
import = ->(size) do
  lines = size.times.map { |i| JSON.generate({ id: "row-#{i}", title: "Certificate", content: "Certificate metadata expiry." }) }.join("\n") + "\n"
  CorpusIntake.call(corpus:, membership:, name: "Native history", kind: "conversation_lines", file: StringIO.new(lines))
end
snapshot = import.call(200)
CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2, processing_method: "local_stream")
SourcePurge.call(source: snapshot.source, membership:)
connection.execute("ANALYZE corpus_items, corpus_analysis_inputs")
import.call(20_000)
analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2, processing_method: "local_stream")
raise "Uncommitted native work" unless connection.open_transactions.zero?
stats = connection.select_all("SELECT relname, reltuples, relpages FROM pg_class WHERE relname IN ('corpus_items', 'corpus_analysis_inputs')")
raise "Statistics already refreshed; repeat with a fresh lab" unless stats.all? { |row| row["reltuples"].zero? && row["relpages"].positive? }
puts stats.to_a.inspect
puts connection.select_values("EXPLAIN #{analysis.corpus_items.reselect('COUNT(*)').to_sql}")
connection.transaction do
  connection.execute("SET LOCAL statement_timeout = '5s'")
  raise "Wrong count" unless analysis.corpus_items.count == 20_000
  raise "Wrong bytes" unless analysis.corpus_items.sum(CorpusAnalysis::RECORD_BYTES_SQL) == 988_890
  raise "Wrong subset" unless analysis.fixed_inputs(item_ids: []).empty?
end
puts "Committed native count, bytes and fixed guard passed."
RUBY
```

The original query raises a statement timeout; do not rescue or call that a pass.
The fix must return the exact count, byte sum and empty requested subset, with no
post-import ANALYZE. The example above was executed unchanged: the exact base
exited 1 with `PG::QueryCanceled` and the nested-loop Join Filter; the fix exited 0
with `Committed native count, bytes and fixed guard passed.` Drop only the
generated base when done.

## Remaining uncertainty

The lab verified a query stall in the failed checkout and the committed native
path, then tested a source-query fix. It did not observe #187's live worker, query
plan or catalog statistics. The completed GitHub log cannot prove that this was
the query that consumed its six hours. That historical attribution remains a
supported hypothesis, not a confirmed fact. Worker isolation worked in the lab;
unbounded native waits remain other possible remote failure sites.

These checks do not claim that integrated `bin/ci`, browser coverage, production
runtime-grant execution or deployment passed in this orb. The parent owns broad
integrated verification; the read change needs no additional database privilege.

A future stalled remote run needs content-free current-test names for each worker,
all Ruby thread stacks, child-process state, PostgreSQL wait/blocking snapshots and
runner memory/OOM evidence. Those facts would distinguish a blocked native child,
queue/row-lock wait, lost worker or progressing scale test. Current logs cannot do
so. This investigation adds no remote instrumentation and changes no active run.

## Joined family-evidence query follow-up — 2 October 2026

Fresh password-only TCP CI found another stalled join in the 100,000-record
partition assertions: full membership joined to source items for DISTINCT tenant
IDs. One such statement stayed active for over twenty minutes without a lock wait.
The production `IssueCluster#source_groups` also uses this join for its complete
family count and retained-byte guard, so changing only the test query is insufficient.

The native regression creates a 200-record family through intake/request/job,
purges its source, refreshes the empty tables' statistics, then creates a
20,000-record family through the same path. It refreshes no populated statistics.
The old `source_groups` COUNT fails its five-second statement bound: one test,
four assertions, one `PG::QueryCanceled` error. Later intake cannot replace that
fixed family. The regression checks all member IDs, historical snapshot, tenant,
exact boolean counts, late full-text risk, critical report and the last fifty rows.

`ClusterMember.with_corpus_item` now keeps an INNER LATERAL source lookup with
`OFFSET 0`, binding all three existing tenant-FK keys: workspace, corpus and item.
The complete keys matter: an ID-only correlated lookup still failed because
PostgreSQL chose the three-column source index with only its third key bound.
The final plan uses all three index conditions. It preserves inner-join rows and
existing tenant lineage; it adds no index, grant, migration or authority.
Family text scans use that same relation in 100-member scalar batches, not an
optimizable ID subquery. Full counts, bytes, expiry, frozen membership and the
50-record/10-MiB page guard remain. The large partition assertions now use this
shared production relation without changing any expectation or assertion.

Focused native regression/model/access checks passed 21 tests / 252 assertions
at seed 1, with zero failures/errors/skips. Full joined TCP CI remains a separate
check. This finding does not establish the cause of historical #187.
