# Rebuild status

Updated 30 September 2026. The [product authority](./PRODUCT.md) supersedes the old
helpdesk milestones. This is **Phase A only**, built and tested on
`rebuild/02-domain-demolition` from local `rebuild/01-product-authority`.
The four authorities are unchanged. This is not the complete evaluation product.

## Built locally

- Removed helpdesk/customer messaging, SLA, account-health/intervention, crews and
  personas, broad memory/Supermemory, operational policy, runtime administration,
  coupled execution ledger, connectors, attachments/converters and old fixtures,
  journeys and documentation. Removed the Go process runner, module/toolchain pins,
  installer/Helm/native topology, release/archive/SBOM helpers and obsolete CI work.
- Detached retained auth/tenancy associations and callbacks. Local sign-in,
  verification/reset, invitations, OIDC, first Owner, break-glass, workspace
  authorization and last-Owner protection remain. Audit is append-only in Ruby and
  PostgreSQL; no notification/retention mutation exceptions remain. No RLS exists.
- Fresh auth migrations and regenerated `db/structure.sql`: 9 application tables,
  2 Rails metadata tables, 10 foreign keys, 10 checks, 1 append-only trigger function
  and 2 audit triggers. Only plpgsql is enabled, not vector. Separate native Solid
  Queue/cache/cable schemas remain. Existing `navishai_development` and
  `navishai_test` were not written, dropped or used for tests.
- New `navishai_lab_development` / `navishai_lab_test` databases; preflight rejects
  old names and every old-domain table before database tasks. Setup refuses reset.
  Unit tests and a renamed disposable legacy database prove rejection before
  schema replacement. That temporary database was removed.
- Server-rendered lab shell with local Geist, restrained blue, light/dark themes,
  native disclosures, keyboard focus and honest empty/access/error states. No fake
  metrics, disabled feature actions or corpus/scenario/eval implementations.
- Orb service is Rails web only; production Compose is web/jobs/PostgreSQL only.
  Setup no longer installs Go, vector, Supermemory, LibreOffice or image machinery.

## Verification

- `bin/rails db:create db:migrate`: new development baseline passes.
- `RAILS_ENV=test bin/rails db:schema:load`: fresh test baseline passes.
- Focused audit/Owner/workspace/preflight/demolition tests: **32 runs, 143 assertions,
  0 failures/errors/skips**.
- Parent integration rerun of `bin/ci`: **passed (41.41s)**; RuboCop **105 files, no offenses**; gem audit **no
  vulnerabilities**; importmap audit **no vulnerable packages**; Brakeman **11
  controllers, 11 models, 26 templates, 0 errors, 0 warnings**; eager load passes;
  Rails **120 runs, 642 assertions, 0 failures/errors/skips**; browser/system **2
  runs, 49 assertions, 0 failures/errors/skips**.
- Eager-load's optional mailer-preview warning was checked directly: retained
  PasswordsMailerPreview loads. No old application model eager-loads.
- System tests exercised auth failure/success, lab, theme controls, keyboard skip,
  permission denial, CSP and no page overflow at 1280/390/320px. Representative
  auth/error/lab screenshots under `.amp/in/artifacts/phase-a/` were inspected with
  explicit expectations. Narrow tab clipping found in the first review was fixed
  by wrapping links; second screenshots confirmed all links readable.
- Orb setup repeated successfully (2.97s / 4.21s), resume 0.08s; supervised web
  responds HTTP 200. Native browser screenshots sufficed; no agent-browser needed.
- Direct risk-based review checked removed routes/constants, membership-based
  access (including sibling organisation workspace denial), SQL FK/role failures,
  audit mutation/truncate failures and preflight. Ponytail Audit and CE Code Review
  were unavailable. `git diff --check` passes.

## Dependency and delivery notes

Removed pdf-reader, image_processing, ruby-vips and orphaned Ascii85/afm/hashery/
ttfunk/ffi. Removed the direct BigDecimal pin; Rails still requires BigDecimal.
The old JSON `<4` cap admitted incompatible JSON 3: initial tests failed tokens,
sessions and JSONB reads. Corrected to `<3`, resolved **2.21.2**, and retained all
relevant auth/security tests. No new production dependency was added. The existing
user-owned `bundler (4.0.20)` checksum line in Gemfile.lock remains; exclude that
addition when staging this slice's lockfile hunks.

## Not built or verified

Corpus/scenario foundations (next Phase B), compiler/calibration, HTTP evaluation
worker/target execution, failures and regression suites are not built. No release,
deployment, live provider, real SMTP/OIDC, customer dataset or customer validation
was attempted. Fresh clean-host package installation and Compose/image/TLS/
backup/restore acceptance remain unverified; current Compose PostgreSQL tag is not
digest-pinned. Last-Owner protection is application-side, not a SQL trigger.
Database owners/superusers can bypass audit triggers and need deployment role
review. See [development](./DEVELOPMENT.md), [hosting](./DEPLOYMENT.md),
[security](./SECURITY.md) and [design](./DESIGN.md) for the retained boundaries.
