# Saved-run failure patterns

The run page groups observed failed checks across grader versions. It does not
regrade outputs, infer root causes or create a new failure record. This replaces
the earlier exact-grader-only grouping described in the run-inspection sections
of DEVELOPMENT.md and DESIGN.md. Saved-run comparisons and human regression
admission keep their existing contracts.

## Inspect a pattern

Each group pairs one fixed support requirement kind (outcomes, actions, forbidden,
escalation or grounding) with one deterministic check type or rubric judgment.
For example, two different graders checking reported tool calls can share the
Actions group. Their tools and requirements need not mean the same thing.
Rubric groups are broad requirement-kind groups, not semantic clusters.

Counts distinguish failed checks, fixed cases and grader versions. Two failed
checks on one case count twice as checks, once as a case. Groups use the case's
fixed check binding and grader definition, not a name, current version, reported
check type, raw judge decision or confidence average. Only effective fail
decisions on failed results enter them; a decision must identify that case's
exact check and grader version. Foreign or mismatched bindings supply no group.

Expand a failed check with the keyboard or pointer to inspect:

- The scenario's fixed version and expert-authored importance. Importance is not
  a calculated severity, business risk or support score.
- The exact failed result, fixed case and existing regression-review route.
- The contract statement, requirement kind/index, check ID and saved reason.
- The fixed grader version, processing version and complete definition.
- The exact bound evidence ID, use, source record, snapshot and retained excerpt.
- The individual saved decision, judge quotes and confidence. Quotes prove
  presence in supplied inputs, not a sound judgment.

Deterministic checks report conditions on target output, not real tool execution
or semantic diagnosis. A failed exact-citation check can mean a missing or invalid
citation. A failed anchored-reply check can mean a missing anchor/reply as well as
wrong reply text. Inspect the definition and saved output before drawing a
conclusion. Grader and source edits never change the displayed historical binding.
New company documents can make a case stale for future execution without changing
its saved result or evidence.

## Failures and uncertainty

The case-outcome tally keeps pass, fail, incomplete, execution error and not
executed separate. Missing or incomplete results do not prove a pass. A failed
case can also contain abstentions or judge errors: inspect these separately below
the patterns. Neither supplies an additional behavioural failure.

Judge confidence stays an individual endpoint report beside that version's fixed
threshold. Confidence strictly below the threshold turns a raw pass/fail into an
effective abstention; equality does not. The raw decision remains in its saved
record. A judge error keeps confidence not supplied. Deterministic confidence is
not applicable. No average, probability, accuracy or overall support score follows
from any of these values. Calibration and authoritative expert labels remain
separate; failure-selected examples do not prove representative accuracy.

## Lineage, privacy and lifetime

`EvaluationRunsController#show` starts from the current workspace's corpus and
run. It checks corpus expiry again under the corpus lock before loading saved
items, their fixed cases/checks, grader versions and evidence. The grouping service
accepts those already-authorised items; it has no independent data lookup.
Source-item loading projects link metadata only, not full source text, titles or
context. Retained check excerpts remain visible and escaped, as do untrusted
reasons, definitions and judge quotes. Evidence links retain snapshot, page and
record identity. Private contract text does not enter SQL query parameters.

Existing composite workspace/corpus/case foreign keys and immutable-result,
check, grader and scenario-version triggers govern every input. The view creates
no receipt, audit event, job, model request or regression admission. It adds no
tables, grants, retention policy, provider consent or runtime privilege. The
existing production runtime grants already cover the tables it reads; it needs no
schema-owner capability. This slice does not claim a new restricted-role host proof.

Expired corpus evidence hides the page before hourly purge. Source purge removes
the underlying runs, results, checks and derived copies through the existing
cascade; there is no independent pattern cache to purge. Backups retain their own
operator policy. A GET cannot recall data already transmitted by a past run.

## Verification and limits

Focused checks:

```sh
bin/rails test test/services/evaluation_failure_patterns_test.rb \
  test/integration/failure_patterns_access_test.rb \
  test/models/evaluation_test.rb test/models/evaluation_run_comparison_test.rb \
  test/integration/evaluation_access_test.rb \
  test/integration/impact_comparison_access_test.rb \
  test/services/production_configuration_test.rb
CHROME_ARGS=--no-sandbox CAPTURE_LAB_SCREENSHOTS=1 bin/rails test \
  test/system/failure_patterns_journey_test.rb \
  test/system/evaluation_journey_test.rb \
  test/system/impact_comparison_journey_test.rb
```

The native checks cover cross-grader/requirement grouping, asymmetric check/case
counts, individual uncertainty, forged decision metadata, fixed history after
edits, escaped content, source projections, SQL-log reads, tenant isolation,
expiry/purge, SQL lineage/immutability, production configuration and unchanged
comparisons/regression admission. Browser checks cover Enter on disclosures,
read-only refresh, exact-result navigation, CSP and horizontal overflow at 1280,
390 and 320 CSS pixels with 2x captures. These narrow Chromium views are not real
phone tests. Full-page captures avoid section-crop reflow and preserve headings.

Screenshots live under `.amp/in/artifacts/failure-patterns/`: empty, execution
errors, deterministic failure, mixed judge failure and mixed uncertainty. Tests
use synthetic saved outputs and local judge stubs, with no model transmission,
customer data or live target. They prove grouping and inspection, not root causes,
customer value, semantic quality, held-out grader accuracy or deployment readiness.
Broad integrated verification belongs to the parent implementation.
