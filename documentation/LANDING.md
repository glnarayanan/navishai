# Support evaluation landing page

Route: `/`, `PagesController#show`. Mode: Persuade. Authority: [PRODUCT.md](./PRODUCT.md).
The page extends the [lab design](./DESIGN.md); it does not replace it.

## Direction contract

- **Thesis:** Turn company Support history and expert judgment into checks for an
  AI support system. Explain the loop, not a universal support score.
- **Identity:** Self-hosted Geist and Geist Mono, neutral surfaces, thin dividers,
  restrained blue actions and the existing native theme/navigation controls.
- **Story:** Corpus → expert scenarios → compiled checks → calibration → failures
  → regression. Show an illustrative SSO case, never fake customer results.
- **First viewport:** A large left-aligned offer and sign-in action beside a compact
  source-to-check example. Stack them without dropping content on narrow screens.
- **Form:** Extend the owner-pinned repository/QA-lab identity in code. No new visual
  world, generated images, dependencies, pricing or customer claims.
- **Finish:** Inspect desktop/mobile and theme states; exercise real sign-in,
  signed-in root redirect, native disclosures, anchors, keyboard access and CSP.

## Product and privacy boundaries

Describe uploaded conversation exports, text/Markdown documents and structured
traces, not live helpdesk connectors. Local analysis proposes term families and
selection reasons; it does not measure semantic coverage. Experts review scenarios
and controlled variants before compilation. Deterministic checks inspect reported
outputs; rubric judges need human calibration. Held-out evidence stays distinct
from development labels. Unknown outcomes and costs stay unknown.

Local intake/analysis sends no model request. Separate operator approvals and human
disclosure consent govern external source processing, targets and judges. Targets
receive visible input and permitted knowledge, not hidden expectations. Judges
receive the fixed requirement, relevant evidence and output. Masking is not full
PII removal; source purge also removes local derived records and cannot recall
remote copies. No customer-data training, customer messaging or vendor integrations
are advertised. Self-hosting needs operator setup, not an implied managed service.

## Routes and ownership

Signed-out visitors can read the page and follow the real sign-in route. First-time
setup appears only while `FirstOwnerBootstrap.available?`. Signed-in root requests
keep their existing redirect to `workspaces_path`; no authentication logic changes.
Page CSS lives in `app/assets/stylesheets/landing.css`, scoped to `.landing`, and
loads through the existing asset pipeline. Shared layout and application CSS stay
unchanged. Native FAQ disclosures need no new JavaScript. Section links opt out of
Turbo so the browser handles fragment scrolling, history and focus directly.

## Verification

Checked 1 October 2026 on the exact `rebuild/67-bounded-mined-labels` base,
Ruby 4.0.6, PostgreSQL 16 and Chromium 154. Native setup installed the locked
JSON 2.21.2 dependency without changing its version.

- `bin/rails test test/controllers`: 47 tests, 339 assertions, no failures, errors
  or skips. Includes public/expired/signed-in root and bootstrap availability.
- `CHROME_BIN=... CAPTURE_LANDING_SCREENSHOTS=1 bin/rails test test/system/landing_test.rb test/system/lab_shell_test.rb`:
  5 tests, 195 assertions, no failures, errors or skips. Uses the installed Chrome
  executable. Covers 1280/768/390/320px, light/dark, sign-in/out, real workspace
  redirect, skip-link focus, section anchors and keyboard-opened disclosures.
- `bin/rubocop`: 304 files, no offenses. `bin/rails zeitwerk:check`: passes.
  Brakeman: no warnings/errors. Gem and Importmap audits: no vulnerabilities.
  `git diff --check`: clean. No separate CSS/ERB formatter or type checker exists.
- Direct risk-based review checked product claims, routes, auth, asset scope and
  data boundaries. Impeccable's detector found only Geist Mono font warnings;
  the owner-pinned fonts remain. Ponytail Audit and CE Code Review were unavailable.

All four final full-page desktop/390px light/dark captures were inspected, along
with the keyboard-opened FAQ and four signed-in theme/width states. Artifacts live
under `.amp/in/artifacts/landing/`: `desktop-light-full.png`,
`desktop-dark-full.png`, `mobile-light-full.png`, `mobile-dark-full.png`,
`public-expanded-390.png` and `auth-states.png`. Captures use 2x scale; narrow
Chromium viewports are not real phones. Checks found no horizontal overflow or
CSP violations. Narrow body text is 16px. The first pass exposed a real fragment
navigation failure; native links fixed it. The final pass confirmed wrapped FAQ
alignment and complete content in both themes.

This slice adds no jobs, receipts, domain writes, SQL relationships or grants;
tenant lineage, immutable versions and expiry/purge behaviour remain unchanged.
Public GET checks create no corpus, scenario, run or audit record. The parent
owns combined full CI and integration. This page makes no live-provider, coverage,
accuracy, cost, customer-acceptance or deployment claim. [STATUS](./STATUS.md)
records current delivery; no merge, release or deployment has occurred.

## Parent integration checks

The integrated headline names SSO handoffs, API fixes and billing rules rather
than a generic AI benefit. It does not imply prebuilt integrations or a passing
customer result. Parent checks include privacy slice 68 and acceptance map 69.

`bin/ci` passed setup, style, native audits, eager loading and 481 Rails tests /
7465 assertions, then failed one old-placeholder logout assertion. The repaired
test checks the actual public sign-in route. The final
`CAPTURE_LAB_SCREENSHOTS=1 CAPTURE_LANDING_SCREENSHOTS=1 bin/rails test:system`
passed 56 tests / 2600 assertions, without failures, errors or skips. Focused
pages/setup/session checks passed 15 / 150; Ruby style passed 305 files. This does
not turn the initially failed full command into a green run.

Parent inspected `integrated-desktop-light-full.png` and
`integrated-mobile-dark-full.png` under `.amp/in/artifacts/landing/` on the current
managed preview. Both contain the complete example/workflow/privacy/footer at 2x.
Executed DOM checks confirm six steps, `/session/new`, no horizontal overflow and
16px body text at 390px. Native tests exercise real sign-in/out, themes, disclosures,
anchors, focus and CSP. Full captures fix the earlier mobile viewport capture's
below-the-fold evidence limit; they do not prove external actions or model quality.
