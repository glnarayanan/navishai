# Evaluation-lab development

The lab runs Rails 8.1, Ruby 4.0.6 and PostgreSQL 16. No Go source, process runner,
Supermemory, vector extension, document converters or provider services remain.
Solid Queue owns bounded evaluation batches; HTTP uses the Ruby standard library.
A separate worker language needs measured workload or isolation evidence.

## Fresh baseline

Install the pinned Ruby with mise, install PostgreSQL and libpq development headers,
then run `bin/setup --skip-server`. Default databases are `navishai_lab_development`
and `navishai_lab_test`. Setup creates/prepares them; it does not reset databases or
seed accounts. `--reset` is rejected.

Never point this rebuild at an old helpdesk database. Preserve/archive that database
and choose a fresh name. Database task preflight checks effective configuration
(including DATABASE_URL overrides) before migration/schema load, rejecting old
default names and legacy tables even after renaming. Boot rejects old default names.
There is no legacy-data migration or compatibility layer.

`db/structure.sql` includes auth/tenancy and corpus migrations, with PostgreSQL
composite workspace foreign keys, checks, uniqueness, immutable snapshot/item
updates and append-only audit triggers. Solid Queue/cache/cable schemas
remain separate Rails-native production databases. No RLS is installed.

## Run and check

- Outside an orb: `bin/dev` starts Rails only.
- In Amp: `.agents/setup` installs/prepares prerequisites, `.agents/resume` checks
  PostgreSQL, and `amp orb services ensure` supervises the web service and returns
  its authenticated portal. Lifecycle files are not active for future checkouts
  until delivered to the default branch.
- `bin/ci` runs setup, RuboCop, gem/importmap audits, Brakeman, eager-load checks,
  full Rails tests and system tests. No checks reference deleted Go code.
- `bin/prove-container-runtime` uses a separately prepared private Docker daemon
  and reviewed image for a disposable production-role, native-jobs and private
  HTTPS proof. It is orb-only, never a deploy command; see [hosting](./DEPLOYMENT.md#disposable-imageruntime-proof).
- `bin/rails test test/services/support_lab_acceptance_test.rb` checks one fresh
  technical-Support fixture through intake, discovery, expert taxonomy/scenario
  review, mixed deterministic/judge checks, held-out labels, HTTP execution and
  same-case regression replay. Network responses and expert judgments are fixtures;
  this proves the engineering loop, not discovery quality or live-model accuracy.
- `CAPTURE_LAB_SCREENSHOTS=1 bin/rails test:system` records lab/auth/error states at
  1280, 390 and 320px under `.amp/in/artifacts/phase-a/` and intake/evidence states
  under `.amp/in/artifacts/corpus/`.

## Corpus intake

Create a corpus inside a workspace. Upload a JSON array with `id`, `title`,
`content` and optional object `context`, an Intercom `conversations` array with
source/parts, or a Zendesk `tickets` array with description/comments. These narrow
shapes are not every vendor export format. Plain UTF-8 text and Markdown also work;
PDF, attachments and live connectors do not. Limits: 10 MiB, 2000 records per upload,
100,000 characters per record. Bad batches roll back as a whole.

The same source name/type and input digest/redaction reuse a snapshot. Changed
input or redaction adds a version; re-uploading an old version selects it again.
Current corpus views use only current, unexpired snapshots. Original files are not
retained: normalised records, SHA-256 input digest and processing version are.
Email masking is the default, not complete PII removal; review other sensitive data
before upload. Email IDs become distinct digest-based record IDs.

Production traces use a JSON array of `support-trace-v1` objects with exactly
`schema`, `id`, `title`, `target_version`, `observed_at`, `input`, `output`,
`observed_failure` and `human_correction`. Observation time must include a timezone.
Input has exactly `situation`, `known_facts` and `knowledge`; each knowledge entry
has `reference` and `content`. Output uses the six-field `support-output-v1` shape
below. Each trace is at most 100 KiB, including metadata; the record text limit
also applies. Failure/correction are text, may be empty, and are source reports,
not expert labels. Unknown fields and hidden expectation fields are rejected.
`test/fixtures/files/production_traces.json` shows the format with synthetic data.

Intake masks nested trace input/output and corrections too, then revalidates the
retained payload. A malformed batch leaves no partial records. Trace source pages
show input, output, reported version/time and corrections. A writer may propose a
scenario from a reported failure; repeats reuse its root identity. The proposal
copies situation/facts, leaves requirements empty and does not grant recorded
knowledge. Experts choose current documents, write expectations and approve the
exact version. A trace without a reported failure cannot seed this proposal path.
Trace payloads do not enter the conversation/document term-discovery baseline.

### Reviewable failure matching

A trace source page suggests at most five current scenario versions from the same
corpus. Local retrieval searches title, situation, taxonomy and non-trace
expectation excerpts. It excludes hidden facts, recorded output, imported
corrections and trace excerpts. At least two distinct terms must overlap after
excluding known-fact keys/values. Candidates sort by shared terms, equal facts,
then version ID. This is literal retrieval, not semantic accuracy or probability.

Bounds are 2000 current versions and 10 MiB of complete candidate text. Exceeding
either bound searches nothing rather than truncating. Candidate inputs load once
per source page, not once per trace. Expired, merged, rejected or stale-document
versions cannot appear. Exact links, shared terms and equal/conflicting/missing
facts help experts compare evidence; null, false, zero and absence differ.

Writers may record match, different or uncertain with a reason on the exact trace
and current version. Corrections append; the paginated history shows 50 decisions
and each author's latest state across all pages. Another expert cannot erase it.
Viewers can inspect candidates/history but cannot decide. Errors retain the chosen
version and reason; changed evidence or access blocks writes. Purge removes the
associations through their source-backed records.

Association does not approve or edit a scenario, grant knowledge, label a
calibration sample, compile, execute or admit a regression. Experts follow the
existing scenario review or propose a separate scenario. Recorded replay still
requires identical visible input. No provider call or automatic consensus occurs.
Synthetic desktop/mobile captures live under `.amp/in/artifacts/failure-matching/`.

Retention is 1–3650 days from the latest import, including a repeat. Expired content
leaves exploration immediately; `SourceRetentionJob` deletes it hourly through
Solid Queue in production. Managers/Admins/Owners can delete a source by typing its
name. In development run `bin/rails runner 'SourceRetentionJob.perform_now'` to
enforce expiry. Intake stays local.

Managing roles can also open **Download retained snapshot** on an exact current
or historical source page and type its source name. The POST attachment contains
complete normalized title/text/context records, source/snapshot identity, input
digest, intake time and processing/redaction versions. It is
`navishai-retained-source-v1` JSON, not a vendor export or the original raw file.
It is not a vendor-format reimport path. Limits are 2000 records / 10 MiB of complete
JSON; larger snapshots fail without a partial download. Read-only source pages
write nothing; successful preparation appends a content-free snapshot audit, not
proof of receipt. Downloads send no data to a provider. Masking can leave personal
or sensitive data, and downloaded copies need their own storage/deletion policy:
local purge cannot recall them. Members/Viewers have no download permission.
The browser proof checks an actual masked historical JSON download and removes
its private temporary copy; desktop/mobile review captures live under
`.amp/in/artifacts/source-export/`.

## Corpus exploration

On a corpus page, follow **Explore current records**. Search a literal phrase of
at most 200 characters across titles, record IDs, normalised text and JSON context,
ignoring case. A source filter narrows the same search. SQL wildcard characters
stay literal; this is not semantic ranking or measured coverage. Only current,
unexpired snapshots appear. Matches paginate at 50 records and retain both filters.

Expand a record to inspect its retained text/context and exact source/snapshot
link. The link reaches the right source page even beyond record 50. Historic
snapshots remain inspectable through their source, not the current search.
Empty/invalid searches keep a recovery path. Search phrases are filtered from
Rails request logs but remain in the browser URL/history; never paste secrets.
Viewer searches queue no work and change no records. Desktop/mobile matches,
empty and invalid states are captured under `.amp/in/artifacts/corpus-exploration/`.

## Local discovery

Request analysis with a 1–100 candidate limit. The job freezes current source-backed
inputs, rechecks workspace access and commits cluster proposals atomically. A
duplicate job does not recreate them. Limits: 2000 records and 10 MiB of source text.
TF-IDF seed clustering uses titles plus the first 4000 conversation characters;
cosine similarity ≥0.3 joins a seed cluster. Explicit critical/risk/reopen mentions
precede nearest-centroid representatives. Every selection retains its reason.
Keyword signals, term clusters and document-term gaps are hypotheses, not measured
issue coverage, diagnosis or proof of failures. Experts rename labels in fixed
taxonomy revisions. Refresh queued results; production needs the jobs service.

## Model-assisted corpus discovery

Follow **Model-assisted corpus discovery** from a corpus. Review the exact source
preview, fixed model/settings and candidate limit, then confirm disclosure. The
operator must approve the exact workspace/HTTPS endpoint in the private
`NAVISHAI_CORPUS_ENDPOINTS` registry in both web and jobs. It has the same entry
shape as the target registry, but target/judge and single-scenario approval cannot
grant corpus disclosure. Never enter credentials in a form or tracked file.

`support-corpus-v1` accepts 1–100 complete conversation/document records within
256 KiB and 1–20 candidates. Nothing is silently sampled or truncated. Existing
scenarios, labels, traces and other corpora stay local. For larger inputs, use
**Bounded multi-request discovery** below. Email masking is not full PII removal; approval must
cover the displayed titles, text and retained context.

The request contains exactly `schema`, `instructions`, `model`, `settings`,
`candidate_limit` and `records`. Each record has `reference` (`corpus-item-ID`),
`kind`, `title`, `content` and `context`. Fixed input IDs/digest, configuration,
protocol and attempt UUID survive later conversation imports. Changed documentation
blocks the attempt rather than silently replacing its evidence.

Responses contain exactly `schema`, `model`, `decision`, `reason`, `clusters`,
`candidates`, `usage` and `cost`. Decision is `proposal` or `abstain`; abstention
has empty clusters/candidates. Each cluster has `label`, `reason`, `members`,
`possible_documentation_gap` and `evidence`. Members partition every disclosed
conversation exactly once; evidence pairs each member's `reference` with an exact
`quote`. Each candidate has `reference`, `reason`, `scenario` and `evidence_links`.
The scenario uses the seven editable scenario fields. Every requirement has a
`kind`, zero-based `index`, disclosed source `reference` and exact `quote` link.
Missing/duplicate/foreign references, invented quotes and extra coverage claims
fail the whole response. The shared transport caps responses at 100 KiB; reported
usage/cost have the judge report shape and are not verified charges.

Quotes prove provenance, not sound judgments. Counts derive from retained members,
not claimed coverage. Experts review taxonomy and mine unapproved versions through
the existing flow; mining copies exact expectation evidence and grants no
target-visible knowledge. Several quotes from one source use a single exact
window of at most 4000 characters; a wider window fails rather than dropping a
requirement's evidence. Action-only candidates still need expert outcomes before
approval. No model result creates approval or authoritative human labels.

Jobs claim once, release locks during transport and recheck membership, retention,
document freshness, digest and purpose before saving. Unknown outcomes never
retry. Writers may interrupt queued work or an attempt running over ten minutes,
then deliberately request another. Refresh only reads; source purge removes local
requests/results and descendants, not remote copies. Model/configuration errors
retain entered text, refresh the preview and clear consent.

`bin/rails test test/services/support_lab_acceptance_test.rb` includes the model
discovery → expert correction → mixed checks → held-out calibration → failed
HTTP fixture → same-case regression loop. Fixture calls and labels do not prove
live discovery or judge quality. Desktop/mobile states are captured under
`.amp/in/artifacts/model-discovery/`.

### Bounded multi-request discovery

Follow **Bounded multi-request discovery** from a corpus. The complete source
preview and actual maximum call plan precede consent. Records expand in a native
disclosure. Consent binds both the source digest and allocation/call-plan digest;
it cannot approve later source changes. The same separate corpus-purpose registry
and fixed endpoint/model/settings govern every call.

Bounds: 2000 complete records / 10 MiB, at most 30 discovery requests and one
reducer. Each ordered conversation batch repeats all current documents and fits
100 records / 256 KiB of encoded record JSON. An unfit complete record/document
set fails before queueing. No sampling, truncation or dropped families.

Each discovery uses `support-corpus-v1` and its own fixed UUID. The reducer uses
`support-corpus-merge-v1`, with exactly schema, instructions, model, settings,
candidate_limit, clusters and candidates. Clusters have reference
(`BATCH-UUID/cluster/INDEX`), label, reason, possible_documentation_gap and one
exact first-member evidence quote. Candidates have reference
(`BATCH-UUID/candidate/INDEX`) and their complete fixed definition. Full membership
quotes stay local; all selected expectations and evidence reach the reducer.
More than 200 intermediate clusters or a request over 1 MiB stops the attempt.

The reducer response has exactly schema, model, decision, reason, usage, cost,
families and candidate_refs. A proposal's families contain label, reason,
possible_documentation_gap and cluster_refs, partitioning every supplied cluster
exactly once. Unique candidate_refs select existing candidates within the requested
1–20 limit. Abstention has empty families/candidate_refs. The reducer cannot invent
members, quotes or definitions; local composition changes only candidate taxonomy
labels. The response/usage/cost bounds remain those of the shared transport.

Before and after each call, the job checks source lifetime, fixed historical inputs,
document freshness, membership and purpose approval. Later conversation intake
does not replace frozen inputs. Any abstention, malformed output, interruption,
revocation or unknown outcome blocks later calls and global proposals. A claimed
analysis cannot resume after a crash. Writers may interrupt batch work immediately;
another analysis requires a deliberate new request and consent.

Receipts show each immutable definition, UUID, disclosed-input digest, result and
reported usage/cost. The composed response reports the final call, not a total;
missing reports remain unknown. Stopped unsent calls say **Not sent — attempt
stopped** even though their retained internal definition state is queued. Partial
receipts cannot be mined. Purge cascades through these local copies; it cannot
recall transmitted data. Synthetic captures live under
`.amp/in/artifacts/batch-discovery/`; they do not establish discovery quality.

Deleting any source clears corpus analyses and taxonomy revisions because they
describe the full input collection. It also deletes all scenarios, including trace
proposals with no analysis parent, and their variants,
versions, evidence, reviews, compiled cases and graders. Grader text may contain
company evidence, so purge clears the corpus-wide library too, including calibration
outputs/labels, targets, runs, results and regression admissions. Suite names remain
without cases. Source records from other sources remain. Expiry blocks derived
reads and writes before the hourly purge.

## Source impact and saved-run comparison

Every source page lists exact evidence dependencies across all retained snapshots,
not just the snapshot being viewed. Versions and fixed cases paginate separately
at 50 records. Follow the version, case and current suite links to review affected
expectations. A policy/document upload marks prior linked document evidence stale;
it never rewrites fixed contracts or results. A newer conversation or trace export
does not invalidate history. These links cannot detect unlinked assumptions or
semantic equivalence. Corpus expiry hides dependencies before purge.

On a run page, choose a baseline under **Compare fixed cases**. The current run is
after; the baseline is before. The picker lists the latest 100 other corpus runs.
The `baseline_id` query also accepts an older same-corpus run; selecting it keeps
it in the picker. Refresh preserves the comparison. This GET reads saved records
without queuing work, transmitting data or changing regression suites.

Pairs need the same fixed case ID and equal frozen visible input. Changed case
definitions, graders or inputs are unmatched, even with the same title. Object
key order does not matter; missing values, null, false, zero and array order do.
Pass → fail is a reported regression; fail → pass is recovery. Missing, error or
incomplete outcomes are unresolved. Links retain both exact results, importance
and unmatched inputs. Observed grader decisions do not establish agent quality.

## Scenario review

Create candidates from a completed analysis; repeating this action reuses the
same candidate identities. Local mining uses source titles, context facts, keyword
diagnostic sentences and selection reasons. It leaves outcomes empty. Model
discovery copies structured proposals and exact quotes, never expert approval.
Historical answers are not approved expectations. Experts must check the starting
situation and source-backed outcomes before approval.

Edit the issue label, importance, known/hidden JSON facts and five requirement
lists. Save creates a fixed version; an unchanged save keeps the version and
approval. Stale edits/reviews cannot overwrite a later revision. Attach exact
document excerpts as expectation evidence or knowledge available to the target.
The form lists up to 100 current documents. Adding a newer snapshot of the same
document/use replaces that evidence only in the new version. Changed documents
mark prior evidence stale; changed conversation exports do not invalidate history.

Approve, reject or merge into another approved scenario by ID. Every decision
records the expert and version. Create a variant from an approved version by
changing one existing fact with exact before/after values, reason and expected
difference. The child keeps parent evidence, requires an expert revision and gets
its own approval. No external processing occurs. Expired evidence hides scenario
reads and blocks writes before purge. Full-page review/variant/error captures live
under `.amp/in/artifacts/scenarios/` when `CAPTURE_LAB_SCREENSHOTS=1`.

## Eval Compiler

Define corpus-owned graders, then compile a current approved scenario. Map every
statement to exactly one grader version and one evidence excerpt from that same
scenario version. Missing, duplicate, foreign, stale or expired mappings fail.
Compilation stores the exact approval, contract, bindings and compiler version.
Repeated submissions with the same bindings reuse the case. A changed binding
creates another numbered definition; later grader edits cannot rewrite it.

Deterministic definitions use `type` and `value`: tool_called, forbidden_tool,
field_collected, citation_present, escalation, policy_branch, text_contains,
text_absent or tool_before. Names/branches match exactly; text checks ignore case
and inspect assistant messages only. A collected value may be false or zero, but
not null or empty. A citation needs an exact quote in permitted knowledge with
the matching corpus-item reference. Tool order uses the first occurrence of each
of two distinct names. These checks verify reported traces, not tool execution or
semantic correctness. Text mentions do not prove a sound diagnosis.

Rubric-judge definitions store a company rubric and a 0–1 abstention threshold.
Saving does not call a model. Self-reported confidence is not a calibrated
probability. An optional fixed execution configuration enables the generic judge
interface below; an offline rubric remains valid and abstains during runs.

The `support-output-v1` shape is bounded to 100 KiB and 100 messages/tool calls/
citations. It requires all six fields and rejects extra fields and wrong types:

```json
{
  "messages": [{"role": "assistant", "content": "Please share the expiry date."}],
  "tool_calls": [{"name": "collect_expiry", "arguments": {}}],
  "collected_fields": {"admin": false},
  "citations": [],
  "escalation": {"triggered": false, "team": null},
  "policy_branch": null
}
```

The target-visible preview contains only situation, known facts and permitted
knowledge excerpts with corpus-item references. It omits title, hidden facts and
expectation fields. Experts must remove answers from the starting context.
Suites group up to 50 fixed cases; adding a case rechecks approval, evidence,
current scenario version and check completeness.
Compiler desktop/mobile/error captures live under `.amp/in/artifacts/compiler/`.

## Scripted evaluation and regression

Managing roles define a target with `rules` and `default_output` JSON. Up to 20
ordered rules compare one named visible known fact with an exact scalar value and
return a support-output-v1 fixture. Missing is not null; false is not absent. The
first match wins. A scripted target cannot run code, call a model or send data externally.
Target edits create versions with fixed configuration and processing version;
stale forms need a reload. This adapter proves machinery, not support-agent quality.

A writer starts a suite run against one target version. The transaction freezes
membership, target-visible input, exact cases/graders and processing version.
Bounds: 50 cases and 100 checks. `EvaluationRunJob` uses the `evaluations` queue;
development can execute a deliberately requested run with
`bin/rails runner 'EvaluationRunJob.perform_now(RUN_ID)'`. Production needs `bin/jobs`.
Repeated/concurrent job delivery claims once, never repeats execution. A worker
crash leaves an unknown/interrupted run; it does not justify an automatic retry.
An expert can interrupt a queued run or one started over ten minutes ago, then
deliberately start a separate run. Access, approval and source lifetime are checked
before each case and before retaining its output. Network calls hold no corpus or
membership locks. Unavailable processing versions stop rather than reinterpret history.

Results retain output and each exact check's pass, fail or abstention, reason and
confidence. Rubrics without a judge abstain. A case fails on any failed check,
passes only when all pass, otherwise stays incomplete. Schema/worker errors are
not behavioural failures. Groups share exact grader versions; they are not semantic
failure clusters or coverage measures. Trace checks do not attest tool execution.

Experts can add a failed result to a regression suite with a reason. Each fixed
admission retains the result, case, human and rationale; repeat submissions reuse
it. Removing membership leaves the admission history. The next target version
tests the same fixed case. Purge removes target/output/rationale copies; expiry
hides them, including suite history, before purge. Inspected browser captures live
under `.amp/in/artifacts/evaluation/`. Configured rubric judges require separate
disclosure confirmation; their errors do not become behavioural failures.

## Recorded production replay

A trace source page lists cases with identical visible input among the first 100
fixed corpus cases, including prior versions. This is input compatibility, not
semantic failure matching or an expert decision. Inspect the contract; execution
still requires its current approved scenario and current company evidence.

A managing role can follow the trace's target-definition link, name the target
and save the prefilled record ID. Choose `Recorded · uploaded trace`; no JSON
configuration is used. A same-corpus foreign key binds each immutable target
version to that exact item. A later trace upload or target revision cannot change
an old run. Old trace snapshots remain historical evidence, not changed policy.

Starting a suite requires every case's situation, known facts and permitted
knowledge (including references) to match the recorded input. Object key order
does not matter. Changed values, omitted fields or changed knowledge refuse to
queue a run. This single-output adapter does not answer unrelated cases; use an
actual target for those. The worker checks again and reads current source expiry.
It grades the retained output locally, never executes the production agent.
Configured rubric judges still require their own consent, case-list token and
operator endpoint approval; replay cannot bypass disclosure.

Results link to the exact trace and retain existing check evidence. Imported
failure/correction text cannot determine pass/fail. Experts can admit an observed
failed result to a regression suite with the normal fixed-case human decision.
A later target tests that same case. Trace expiry hides derived records before
purge; source purge removes target/run/output and regression copies too. Fixture
browser captures live under `.amp/in/artifacts/recorded-replay/`.

## Generic HTTP target

The operator sets `NAVISHAI_EVALUATION_ENDPOINTS` in both web and jobs as a JSON
array. The default `[]` denies all HTTP targets. Each entry binds an exact URL to
a numeric workspace ID, with an optional bearer token:

```json
[{"workspace_id": 123, "endpoint": "https://agent.example.com/evaluate"}]
```

This is an example, not a configured endpoint. If authentication is needed, add
`bearer_token` to that entry through your private secret environment. Never paste
it into the target form, commit the registry, or print it in logs. Rotate secrets
with the environment, not a new case; credentials are not dataset artifacts.
No key or credential reaches a target version, result, audit event or browser.
The registry must be consistent across web/jobs; removal blocks future dispatch.

A Manager/Admin/Owner chooses HTTP and saves `{"endpoint":"https://…"}`. Saving
does not connect. A writer reviews the fixed visible inputs and exact endpoint,
checks disclosure confirmation and starts a run. The form's case-list digest must
match current suite membership, including HTTP runs without configured judges.
A changed suite requires a reload, review and fresh confirmation before queueing.
Each target POST sends:

```json
{"schema":"support-target-v1","input":{"situation":"…","known_facts":{},"knowledge":[]}}
```

Input is the fixed case preview, including permitted knowledge references/excerpts.
No expectations, title, hidden facts or workspace identity enter the body. Experts
must remove sensitive data or answers from that preview. The endpoint returns the
six-field support-output-v1 JSON documented above, not a provider-specific payload.
`Idempotency-Key` is the item's fixed UUID; the endpoint owns remote deduplication.

HTTPS port 443 only; no URL credentials, query or fragment. Every call checks all
DNS answers, rejects private/special-use/translated addresses and pins one approved
public address while retaining TLS hostname/certificate verification. No redirects,
proxy inheritance, address fallback, compression or automatic retries. A 30-second
total deadline includes DNS; open/read/write bounds are 5/10/10 seconds. Input is
at most 1 MiB; streamed JSON output is at most 100 KiB and must be valid UTF-8.
Deployment network rules must also deny private destinations; address checks are
not a substitute for operator egress policy. Internal/private targets are not supported.

Result metadata records adapter, processing version and elapsed time including
checks. Cost remains unknown. HTTP, timeout and schema errors are execution errors,
not support failures or regression candidates. A timeout may mean the remote
system acted despite no retained response. Refresh/duplicate delivery never sends
again; a deliberately new run has a new request key and may incur another charge.
Stopping, expiry or deletion cannot recall an in-flight or already delivered
request. Changes after dispatch discard its local result and block later cases.
The remote endpoint has its own retention/deletion policy.

Tests use stubbed DNS/streams and a real local TLS socket with test-only routing,
never a customer endpoint. Desktop/mobile setup, approval and unknown-outcome
captures live under `.amp/in/artifacts/http-target/`.

## Generic model judge

A rubric version may add `execution` through the optional Judge configuration JSON
field. This example is not a configured endpoint:

```json
{
  "endpoint": "https://judge.example.com/grade",
  "model": "company-judge-2026-09",
  "settings": {"temperature": 0, "max_output_tokens": 1024, "seed": null}
}
```

Only these fields are accepted. Use a pinned model identifier; the lab cannot
prove that an endpoint actually uses it. Output-token bounds are 256–4096; seed
is null or an integer from 0 to 2147483647. The endpoint must honor the fixed
settings, reject unsupported settings and return its reported model. Temperature
zero and a seed do not make a model reproducible; fixed inputs/settings and retained
decisions make the attempt inspectable. Changing any definition creates a version;
compiled cases and calibration sets keep the old one.

The private `NAVISHAI_EVALUATION_ENDPOINTS` registry must separately approve the
judge's exact URL/workspace in web and jobs. The shared JSON transport applies all
target TLS, DNS, bounds, timeout and no-retry controls to judge calls. Saving checks
approval but sends nothing. No direct vendor payload or model CLI is built in.
Operators supply a customer-controlled model gateway implementing this contract;
the gateway must not silently fall back to a different model or settings.

`support-judge-v1` POSTs contain schema, fixed instructions, model, settings, rubric,
requirement, context (the target-visible preview), company_evidence (the exact check
excerpt), and target_output (support-output-v1). Hidden facts, full corpus, labels
and other predictions are absent. Evidence/output are untrusted data, not commands.
The gateway must enforce that separation; a prompt alone does not prevent injection.

Response fields are exactly schema, model, decision, reason, confidence, quotes,
usage and cost. Schema/model must match. Decision is pass/fail/abstain; reason is
1–2000 characters; confidence is a finite number from 0 to 1. At most ten quotes
contain only reference and quote (1–2000 characters). References are
`company_evidence` or `target_output`; quotes must occur exactly in the sent excerpt
or the JSON-serialized output. Pass/fail need quotes from both. This checks citation
existence, not whether a quote supports the judgment.

Usage is null or `{ "input_tokens": 300, "output_tokens": 70 }` with non-negative
integers up to one billion. Cost is null or `{ "currency": "USD", "micro_units": 27 }`
with a three-letter uppercase currency and 0–one trillion micro-units. Both are
endpoint reports, not verified charges. Unknown values stay null. Low confidence
becomes abstention; the raw decision remains inspectable. Invalid schema/model,
invented quotes and transport failures are errors, never behavioural labels.

Suite runs require their own judge-disclosure checkbox, separate from target
disclosure. A case-list digest binds consent to the definitions and judge endpoints
shown; changed membership requires a reload and new confirmation. Each check uses
an opaque request key derived from the fixed item UUID/check ID. Calls occur outside
database locks; access, current approval and evidence are rechecked before each
check and before retaining output. Sent data cannot be recalled.

Calibration samples require separate consent for each fixed attempt. The native
`CalibrationJudgeRunJob` claims once and creates one immutable prediction; duplicate
delivery/refresh never calls again or overwrites labels. A crash, revocation or stale
evidence interrupts the attempt. Experts may interrupt queued or over-ten-minute
running attempts. Use a new calibration set for another attempt, never rewrite
the fixed prediction. First-label hiding still applies after the judge completes.
Expiry/purge hide/delete attempts and predictions along with their source-backed
samples. Fixture/browser captures live under `.amp/in/artifacts/judge/`; they do
not prove live model behavior, accuracy or cost.

## Source-backed model scenario proposals

Open **Model scenario proposal** on a current, active scenario version. Preview
its exact starting context and linked excerpts, enter model configuration using
the same endpoint/model/settings shape as a judge, and confirm disclosure.
The private `NAVISHAI_SCENARIO_ENDPOINTS` registry must approve that exact URL and
workspace in both web and jobs. Its entry shape matches the evaluation registry,
but its purpose is separate: target/judge approval cannot disclose sources for
scenario processing. Default is empty. Compose forwards it to both processes;
credentials never belong in model JSON or tracked files.

`source-scenario-v1` uses the existing bounded HTTPS transport. Requests contain
only schema, fixed instructions, model, settings, starting_context (situation and
known_facts), and company_evidence (reference/content pairs). The input must have
1–20 linked excerpts and at most 64 KiB of encoded context/evidence. The shared
100 KiB response limit and 30-second no-retry deadline still apply. Hidden facts,
existing expectations, reviews, labels and unrelated corpus data stay local.

Response fields are exactly schema, model, decision, reason, scenario,
evidence_links, usage and cost. Schema/model must match; decision is proposal or
abstain, and reason is 1–2000 characters. A proposal's scenario has exactly title,
situation, taxonomy_label, importance, known_facts, hidden_facts and requirements,
under the existing scenario text/JSON/statement bounds. Requirements have outcomes,
actions, forbidden, escalation and grounding arrays, with at least one outcome.
Each statement needs exactly one evidence link with kind, zero-based index,
reference and quote (1–2000 characters). References must identify a disclosed
`scenario-evidence-<id>` excerpt and quotes must occur exactly within it. Duplicate,
missing, invented or foreign quotes are errors. Abstain requires scenario null and
evidence_links empty. Usage/cost use the judge's optional report schema; neither
quotes nor endpoint reports establish correctness, reproducibility or charges.

One attempt binds to the fixed version/model/settings/request UUID. Native jobs
claim once, send outside locks and recheck membership, source and purpose approval
before retention. Refresh or duplicate delivery cannot send again. Experts can
interrupt queued or over-ten-minute running attempts; a new deliberate scenario
revision is needed for another attempt. Errors may have unknown remote outcome.
Deletion cannot recall sent data, but purge cascades through all local copies.

The suggestion is read-only. It never advances a scenario, approves a version,
creates labels or compiles cases. Experts revise source-backed expectations in the
existing editor and review that exact version themselves. A later edit cannot be
overwritten by an older proposal completing. This interface does not replace local
taxonomy/selection or prove semantic extraction quality. Synthetic browser captures
live under `.amp/in/artifacts/scenario-proposals/`; no live model ran.

## Expert calibration

Create a set for one exact grader version. Add up to 100 support-output-v1 samples
bound to compiled checks using that version. Choose development or held-out
explicitly; no cohort is preselected. An identical JSON output on the same check
reuses its sample regardless of key order only when its origin also matches; it
cannot change cohorts or acquire different result provenance. Creation rechecks
current scenario approval and source evidence. Deterministic predictions run locally;
rubric samples need an explicitly requested judge attempt. Neither upload nor label
sends data out.

On a retained result, **Add this saved output to calibration** offers sets for
the case's exact grader versions. Select a set, case check and cohort; the server
copies only that result's fixed output and case identity, ignoring supplied output.
Execution errors and results without output cannot become samples. Changed or
unapproved scenarios, stale evidence, expired sources and foreign cases are blocked.
The sample retains exact result/run provenance, not machine judgments or human
labels. Result/run links stay hidden before a writer's first label; the neutral
identities remain visible. This reduces anchoring, not access rights. Selected
failures are biased examples, not representative held-out measurement; examples
used to tune belong in development. Each expert must still supply their own label.
Desktop/mobile live selection, retained-error, blind and revealed captures live
under `.amp/in/artifacts/result-calibration/`.

Experts label pass, fail or uncertain and give their evidence. The first judgment
view hides machine and other experts' labels to reduce anchoring, not to promise a
double-blind experiment. Corrections append records and reject stale form tokens.
Reports use the latest label per expert; conflicting or uncertain judgments cannot
supply ground truth. Held-out and development counts never mix. Failure is positive
in confusion counts, precision/recall and machine/expert disagreement. Zero
denominators show no evidence, not 0% or 100%. Pairwise agreement uses only certain
expert-label pairs and is not chance-corrected. Small selected sets do not establish
population accuracy. Do not tune on held-out samples.

Use **Review focus** on the set page to find missing personal labels, expert disputes,
uncertainty, machine/expert disagreement or missing usable predictions. The list
puts missing personal labels first. Until you label a sample, its row cannot reveal
other judgments through its state/order. **Start next unlabelled review** opens one
fixed sample; it does not submit a label or call a judge. Labels still need your
decision and rationale. A correction changes the next report, not the label history.

Filters retain the chosen cohort but never narrow report counts. Clear the focus to
inspect every sample; changing cohort clears the focus. Missing/abstaining
predictions cannot count as agreement. Viewers retain the read-only sample list
without these review controls. Desktop/mobile queues, a dispute filter and an empty
focus are captured under `.amp/in/artifacts/calibration-review/`.

Calibration sets, samples, predictions and labels reject Ruby/SQL updates and use
composite same-corpus/grader relationships. Expiry hides them before purge; source
purge removes them through case and grader relationships. Audit keeps no outputs
or label rationale. Screenshots live under `.amp/in/artifacts/calibration/`.

For first-Owner setup configure a random 32+ byte `NAVISHAI_BOOTSTRAP_TOKEN` and a
future ISO 8601 `NAVISHAI_BOOTSTRAP_TOKEN_EXPIRES_AT`; use `/setup`. Remove them after
bootstrap. No demo identity or customer content is seeded. Authentication fixtures
are test-only and retain their existing identities. Do not load fixtures into an
existing development database.

Dependencies were removed with native `bundle lock --local` / `bundle install`:
pdf-reader, image_processing, ruby-vips and their orphaned dependencies. BigDecimal
remains transitively required by Rails. JSON is constrained below 3 because Rails
8.1.3.1 passes parse options positionally; JSON 3 breaks tokens, sessions and JSONB.
The pre-existing Bundler checksum addition in Gemfile.lock is user-owned, not part
of this slice's staged changes.
