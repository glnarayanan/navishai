# Support evaluation domain

These terms belong to the 30 September 2026 product reset. They do not rename old helpdesk records.

| Term | Meaning |
|---|---|
| Organisation | Company that owns workspaces. Organisation ownership alone grants no cross-workspace access. |
| Workspace | Isolated evaluation lab with its own sources, experts, scenarios, definitions, targets, and runs. |
| Source | Origin of company evidence: an export, document, policy, or later a read-only connection. |
| Source snapshot | Fixed source content at one intake time, with digest, origin, redaction policy, and processing version. |
| Corpus | A named collection of source-backed records to analyse together. |
| Corpus item | One historical conversation or document, not a live ticket. |
| Taxonomy | Company's reviewed issue families; a proposal has no expert authority until reviewed. |
| Issue cluster | Related corpus items with a proposed issue label, examples, and disclosed selection method. |
| Scenario | Stable identity of a testable support situation, separate from its evidence and revisions. |
| Scenario version | Fixed context, facts, expected behaviour, importance, and source evidence at one revision. |
| Scenario family | Real-source scenario and its controlled variants. |
| Variant | Child scenario with named variable changes, reason, and changed expectations bound to a parent version. |
| Evidence | Link to an exact source snapshot/item and the excerpt that supports a claim. |
| Review | Expert decision on an exact proposed version: approve, reject, amend, or merge. |
| Eval contract | Structured requirements and prohibitions compiled from a reviewed scenario version. |
| Eval case | Executable scenario version plus contract and grader versions. |
| Eval suite | Named selection of cases; a run freezes its membership and versions. |
| Grader | A check of one behaviour. Deterministic checks and rubric judges have distinct evidence and limits. |
| Grader version | Fixed check definition, rubric, threshold, and optional model settings. |
| Human label | Attributable expert judgment on exact evidence/output and definition versions. |
| Calibration set | Labelled examples used to measure a grader; training and held-out examples stay distinct. |
| Evaluation target | System under test, not a NavishAI support persona. |
| Evaluation run | One attributable execution against frozen target settings, cases, and graders. |
| Evaluation result | Retained target output and individual grader decisions, evidence, uncertainty, and execution errors. |
| Failure cluster | Results grouped by shared behavioural failure, not a universal support score. |
| Regression case | Reviewed failed case retained in a suite to test future target versions. |
| Classifier | Later, a cheaper learned check for a stable repeated judgment, validated against held-out expert labels. |

## Rules

- Human decisions outrank machine proposals. Approval of one version does not approve its next revision.
- A changed source never changes a prior scenario, case, label, or run. A dependent definition may need a new version.
- Evidence links cannot cross workspaces. A variant must retain both its original evidence and its explicit counterfactual changes.
- Merging preserves the rejected/merged identity and provenance; it does not erase why a case entered the corpus.
- An execution error is not a behavioural failure. An uncalibrated judgment is not a proven label.
- Frequency, risk, coverage, confidence, and severity are different facts. Counts alone do not measure scenario quality.
