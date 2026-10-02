# Support evaluation domain

These terms belong to the 30 September 2026 product reset. They do not rename old helpdesk records.

| Term | Meaning |
|---|---|
| Organisation | Company that owns workspaces. Organisation ownership alone grants no cross-workspace access. |
| Workspace | Isolated evaluation lab with its own sources, experts, scenarios, definitions, targets, and runs. |
| Source | Origin of company evidence: an export, document, policy, or later a read-only connection. |
| Source snapshot | Fixed source content at one intake time, with digest, origin, redaction policy, and processing version. |
| Corpus | A named collection of source-backed records to analyse together. |
| Corpus item | One historical conversation, document or recorded production trace, not a live ticket. |
| Production trace | Fixed visible input and reported agent output, target version, observation time, reported failure and correction. Reports are source data, not authoritative labels. |
| Recorded replay | Local grading of an exact source output against identical visible case input, not a new agent execution. |
| Taxonomy | Company's reviewed issue families; a proposal has no expert authority until reviewed. |
| Taxonomy version | Fixed expert labels for some or all clusters from one corpus analysis. Unreviewed clusters stay proposals. |
| Issue cluster | Related corpus items with a proposed issue label, examples, and disclosed selection method. |
| Scenario | Stable identity of a testable support situation, separate from its evidence and revisions. |
| Scenario version | Fixed context, facts, expected behaviour, importance, and source evidence at one revision. |
| Model scenario proposal | Non-authoritative structured suggestion on one fixed scenario version, with exact source quotes, model/settings and a separate disclosure purpose. It cannot change a scenario or human decision. |
| Scenario family | Real-source scenario and its controlled variants. |
| Variant | Child scenario with named variable changes, reason, and changed expectations bound to a parent version. |
| Evidence | Link to an exact source snapshot/item and the excerpt that supports a claim. |
| Review | Expert decision on an exact proposed version: approve, reject, amend, or merge. |
| Eval contract | Structured requirements and prohibitions compiled from a reviewed scenario version. |
| Eval case | Fixed compilation of an approved scenario version, its contract, check bindings and grader versions. |
| Check binding | One contract statement paired with an exact grader version and evidence from that scenario version. |
| Eval suite | Named selection of cases; a run freezes its membership and versions. |
| Grader | A check of one behaviour. Deterministic checks and rubric judges have distinct evidence and limits. |
| Grader version | Fixed check definition, rubric, threshold, and optional model settings. |
| Human label | Attributable expert judgment on exact evidence/output and definition versions. |
| Calibration set | Output samples for one fixed grader version; development and held-out samples stay distinct. |
| Calibration sample | Fixed recorded output, cohort and compiled check that experts judge. |
| Calibration prediction | Machine decision on a fixed sample, distinct from authoritative human labels. |
| Calibration judge attempt | One consented, once-claimed execution on a fixed sample. It cannot overwrite a prediction or label. |
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
- Expectation evidence stays hidden from a target; knowledge evidence is an explicit excerpt the expert permits it to use.
- A source-backed human expectation is not a claim that the historic answer was correct. Mining cannot approve it.
- A document change makes dependent evidence stale. A newer conversation export does not erase a fixed historical case.
- Compilation covers every contract statement exactly once. A case retains its exact approval and bindings; an edit creates a new definition.
- A deterministic trace check is not proof that an external tool ran or that a response is semantically correct.
- Labels retain each expert's history. Reports use their latest decisions; disagreement or uncertainty cannot supply ground truth.
- Calibration treats failure as positive. False positives flag good behaviour; false negatives miss bad behaviour. Undefined rates remain unknown.
- Held-out samples measure a fixed grader; development samples support changes. Neither cohort proves accuracy across the corpus.
- A run freezes membership and visible inputs at request time. Target, suite and grader edits never rewrite its definitions or results.
- A claimed run does not retry after an unknown outcome. Another execution requires a deliberate new run.
- An HTTP run needs exact per-workspace operator endpoint approval and human disclosure confirmation. Credentials are not artifacts; the immutable item UUID identifies its attempt, not proof of remote exactly-once execution.
- A result passes only when every check passes. An abstention cannot become a pass; an execution error cannot become a support failure.
- A regression admission retains an exact failed result, fixed case, human and reason. Later membership removal does not erase that decision.
- Source impact follows exact evidence through all retained snapshots into current and historical versions, fixed cases and current suite membership. It cannot find unlinked assumptions or decide that changed prose has the same meaning.
- Run comparisons require the same fixed case and identical frozen visible input. Pass → fail is a reported regression; fail → pass is recovery. Unknown results stay unresolved and changed definitions or inputs stay unmatched.
- A model proposal quotes only the fixed excerpts disclosed for its version. Quotes do not prove correct expectations. Existing target/judge approval cannot authorise source processing; proposals never inherit expert approval or change human labels.
