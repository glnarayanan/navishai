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
| Corpus analysis | One fixed-input discovery method proposing company-specific families and scenario candidates. Model output has no expert authority. |
| Discovery batch | Fixed source allocation, digest, request UUID and once-only receipt within one consented analysis. The reducer groups existing proposals; it cannot invent definitions or approve them. |
| Production trace | Fixed visible input and reported agent output, target version, observation time, reported failure and correction. Reports are source data, not authoritative labels. |
| Trace association | An expert's match, different or uncertain decision on an exact trace and scenario version, with append-only reasons. It is neither scenario approval nor a calibration label. |
| Recorded replay | Local grading of an exact source output against identical visible case input, not a new agent execution. |
| Follow-up plan | Expert-authored immutable ordered literal conditions and user messages. Separate from hidden facts; a new plan needs ordinary source-backed approval. |
| Conversation turn receipt | Content-free request key, input digest, elapsed time and reported attempt outcome. Not proof of remote execution or tool use. |
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
| Error-cost assumptions | Optional fixed human costs, common unit and rationale for false-positive and false-negative judgments. Not verified business costs or authority to spend. |
| Calibration sample | Fixed output, explicit cohort and compiled case/check that experts judge; optionally backed by one exact saved result. |
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
- Snapshot reuse requires the same source, input digest, redaction, processing version and masking-rule fingerprint. Changed processing or rules create a new snapshot; masking cannot silently merge keys or record identities. Invalid repeats cannot bypass validation through retained history.
- Exact-text masks come from an explicit author-supplied list, not inferred PII or disclosure policy. Snapshots retain its fixed fingerprint/count, not the list. Prior snapshots and approvals stay unchanged.
- A changed source never changes a prior scenario, case, label, or run. A dependent definition may need a new version.
- Evidence links cannot cross workspaces. A variant must retain both its original evidence and its explicit counterfactual changes.
- Scenario revisions and variants compare retained JSON values with types intact, including nested numbers. Integer 0 differs from float 0.0; object-key order alone changes nothing, while array order matters. Each changed version still needs expert review.
- Trace matching uses the same recursive typed comparison for equal and conflicting known facts. Equal literal terms cannot hide nested numeric differences or turn a hint into an expert decision.
- Merging preserves the rejected/merged identity and provenance; it does not erase why a case entered the corpus.
- An execution error is not a behavioural failure. An uncalibrated judgment is not a proven label.
- Frequency, risk, coverage, confidence, and severity are different facts. Counts alone do not measure scenario quality.
- Expectation evidence stays hidden from a target; knowledge evidence is an explicit excerpt the expert permits it to use.
- A source-backed human expectation is not a claim that the historic answer was correct. Mining cannot approve it.
- A mined draft label may shorten a source term to 500 characters. The full proposal and evidence stay fixed and inspectable; shortening supplies no expert label or approval.
- A document change makes dependent evidence stale. A newer conversation export does not erase a fixed historical case.
- Compilation covers every contract statement exactly once. A case retains its exact approval and bindings; an edit creates a new definition.
- A deterministic trace check is not proof that an external tool ran or that a response is semantically correct.
- A response-scoped check examines each assistant reply after a matching user message, not text anywhere in the transcript. It is not an interactive turn simulation or proof that new facts reached a target incrementally.
- Labels retain each expert's history. Reports use their latest decisions; disagreement or uncertainty cannot supply ground truth.
- Calibration treats failure as positive. False positives flag good behaviour; false negatives miss bad behaviour. Undefined rates remain unknown.
- Error-cost assumptions belong to one fixed calibration set and grader version. Changing them needs a new set. Observed weighted mistakes use only compared, certain labels within that cohort or preview; absent assumptions or comparisons remain unknown. No defaults or inherited values.
- Held-out samples measure a fixed grader; development samples support changes. Neither cohort proves accuracy across the corpus.
- Saved results can supply fixed calibration output, not expert labels. A duplicate cannot replace its manual/different-result origin or cohort. Selected failures do not establish held-out representativeness.
- A run freezes membership and visible inputs at request time. Target, suite and grader edits never rewrite its definitions or results.
- A claimed run does not retry after an unknown outcome. Another execution requires a deliberate new run.
- An HTTP run needs exact per-workspace operator endpoint approval and human disclosure confirmation. Credentials are not artifacts; the immutable item UUID identifies its attempt, not proof of remote exactly-once execution.
- A result passes only when every check passes. An abstention cannot become a pass; an execution error cannot become a support failure.
- A regression admission retains an exact failed result, fixed case, human and reason. Later membership removal does not erase that decision.
- Source impact follows exact evidence through all retained snapshots into current and historical versions, fixed cases and current suite membership. It cannot find unlinked assumptions or decide that changed prose has the same meaning.
- Run comparisons require the same fixed case and identical frozen visible input. Pass → fail is a reported regression; fail → pass is recovery. Unknown results stay unresolved and changed definitions or inputs stay unmatched.
- A model proposal quotes only the fixed excerpts disclosed for its version. Quotes do not prove correct expectations. Existing target/judge approval cannot authorise source processing; proposals never inherit expert approval or change human labels.
- Model corpus discovery needs consent for its exact complete source preview and its own operator purpose. Proposed families must account for every disclosed conversation once. Mining may copy source-backed definitions but grants neither approval nor target-visible knowledge. Abstention and execution error cannot become discovered families or authoritative labels.
- Batch consent fixes source allocation and the maximum call plan. Stopped or unknown attempts cannot resume, retry or publish partial global families. A later conversation import cannot replace already disclosed historical inputs; changed company documents still block processing.
- Family source counts use complete fixed members and full-family denominators. Exact uploaded booleans, missing/nonboolean values, reported critical impact and literal text mentions stay separate. None verifies risk, an outcome, model importance or an expert label.
- Expert nomination adds a local unapproved draft from one fixed member, with its source and author's reason. It never changes the analysis's selection or supplies an authoritative expectation or calibration label. Existing scenarios and decisions remain unchanged.
- Literal failure retrieval suggests current versions for review. Each expert keeps their own association history; a match cannot settle agreement, revise expectations, permit recorded replay with changed input or admit a regression.
- A selected trace opens an existing version for explicit expert revision; it never copies a reported correction into expectations. Distinct trace/conversation records add evidence. Only current documents replace same-source, same-use evidence. Retained historical traces stay eligible until expiry. Saving changes needs fresh review; prior cases and associations stay fixed.
- An expert may replace the expectation quote on the scenario's own fixed conversation with another exact excerpt from that record. It stays hidden from the target, leaves other evidence and prior versions fixed, and needs fresh review when changed. Blank or identical quotes cannot reset approval; newer exports cannot supply a substitute quote.
