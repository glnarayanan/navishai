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

Retention is 1–3650 days from the latest import, including a repeat. Expired content
leaves exploration immediately; `SourceRetentionJob` deletes it hourly through
Solid Queue in production. Managers/Admins/Owners can delete a source by typing its
name. In development run `bin/rails runner 'SourceRetentionJob.perform_now'` to
enforce expiry. No export route or external processing exists in this slice.

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

Deleting any source clears corpus analyses and taxonomy revisions because they
describe the full input collection. It also deletes their scenarios, variants,
versions, evidence, reviews, compiled cases and graders. Grader text may contain
company evidence, so purge clears the corpus-wide library too, including calibration
outputs/labels, targets, runs, results and regression admissions. Suite names remain
without cases. Source records from other sources remain. Expiry blocks derived
reads and writes before the hourly purge.

## Scenario review

Create candidates from a completed analysis; repeating this action reuses the
same candidate identities. Mining uses source titles, context facts, keyword
diagnostic sentences and the analysis selection reasons, not a model. It leaves
outcomes empty: historical answers are not approved expectations. Experts must
write a reusable starting situation and source-backed outcomes before approval.

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

## Expert calibration

Create a set for one exact grader version. Add up to 100 support-output-v1 samples
bound to compiled checks using that version. Choose development or held-out before
review; an identical JSON output on the same check reuses its sample regardless of
key order and cannot change cohorts. Creation rechecks current scenario approval
and source evidence. Deterministic predictions run locally; rubric samples need an
explicitly requested judge attempt. Neither upload nor label sends data out.

Experts label pass, fail or uncertain and give their evidence. The first judgment
view hides machine and other experts' labels to reduce anchoring, not to promise a
double-blind experiment. Corrections append records and reject stale form tokens.
Reports use the latest label per expert; conflicting or uncertain judgments cannot
supply ground truth. Held-out and development counts never mix. Failure is positive
in confusion counts, precision/recall and machine/expert disagreement. Zero
denominators show no evidence, not 0% or 100%. Pairwise agreement uses only certain
expert-label pairs and is not chance-corrected. Small selected sets do not establish
population accuracy. Do not tune on held-out samples.

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
