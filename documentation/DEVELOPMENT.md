# Evaluation-lab development

The lab runs Rails 8.1, Ruby 4.0.6 and PostgreSQL 16. No Go source, process runner,
Supermemory, vector extension, document converters or provider services remain.
Go can return with a bounded HTTP evaluation worker when Phase D earns it.

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
versions, evidence and reviews. Source records from other sources remain.

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
