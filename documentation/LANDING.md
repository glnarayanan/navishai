# Support evaluation landing page

Route: `/`, `PagesController#show`. Mode: Persuade. Authority: [PRODUCT.md](./PRODUCT.md).
The page extends the [lab design](./DESIGN.md); it does not replace it.

## Direction contract

Owner-approved on 17 October 2026 ("Category standard"): neutral SaaS in the
style of Linear, Vercel and the Stripe Dashboard, played straight.

- **Thesis:** The evaluation lab for AI in technical support. Company Support
  history and expert judgment become tests; no universal support score.
- **Identity:** Self-hosted Geist on the lab's neutral tokens (see
  [DESIGN](./DESIGN.md)). Near-black primary actions, thin borders, 12px panel
  radius, status pills reused from the app. No eyebrows, gradient text or
  generated imagery.
- **Header:** The public header carries the brand, the "On this page" links
  (How it works, Example, Data boundaries), the theme switch, Sign in and a
  "Request a pilot" button that hides below 40rem. Below 60rem the links wrap to
  a second row so they stay reachable on phones.
- **First viewport:** A centred headline, one lead paragraph, "Request a pilot"
  and "How it works", then an HTML product preview of a run page (sidebar, case
  table with result pills, failed-check panel). The preview is captioned
  "Illustrative data, not customer data or a real run" and uses demo case titles,
  never customer results. It drops the sidebar below 64rem, stacks the panel below
  60rem and hides secondary columns below 40rem.
- **Story:** why generic benchmarks fall short (three cards) → six workflow steps
  as numbered cards → the authored SSO example with its variant disclosure → the
  failure-to-regression loop → data boundaries → FAQ → pilot close.
- **Close:** A bordered panel asks for a pilot with one primary
  `mailto:hello@navishai.com?subject=NavishAI%20pilot` action, the contact address
  and one founder line without employer names. No form or backend handles pilot
  requests.
- **Footer:** "© 2026 NavishAI", the contact `mailto:`, Privacy, Terms and a Back
  to top link that targets the current page's `h1` id.
- **Finish:** Inspect desktop/mobile and theme states; exercise real sign-in,
  signed-in root redirect, native disclosures, anchors, keyboard access and CSP.

## Privacy and Terms pages

`/privacy` and `/terms` (`PagesController#privacy`, `#terms`) render for signed-out
and signed-in visitors and share the landing footer. Their text is draft for owner
review and not legal advice; it names no legal entity or address. Privacy describes
what the site actually does: no analytics or third-party assets, request logs with
IP address and path, the CSRF session cookie, the opt-in `navishai_theme` cookie and
signed-in session/workspace cookies. Its lab section restates the data boundaries
below. Terms is a short pre-launch notice: self-hosted, no managed service or
public signup, provided as-is during early access, contact by email. Update both
pages when cookies, logging, analytics or the boundaries change.

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

Signed-out visitors can read the page, follow the header's real sign-in route or
email a pilot request. First-time setup appears only while
`FirstOwnerBootstrap.available?`. Signed-in root requests keep their existing
redirect to `workspaces_path`; no authentication logic changes. Page CSS lives in
`app/assets/stylesheets/landing.css`, scoped to `.landing` plus the public-header
additions; the legal pages reuse it under `.landing-legal`, and the footer is
`app/views/pages/_footer.html.erb`. The landing view fills the public header's
optional `:public_nav` and `:public_actions` blocks; other public pages leave them
empty. Native FAQ disclosures need no new JavaScript. Section links opt out of
Turbo so the browser handles fragment scrolling, history and focus directly.

## Verification

The 17 October 2026 redesign is covered by `test/controllers/pages_controller_test.rb`
and `test/system/landing_test.rb`: headline, six workflow steps, preview caption,
header sign-in, hero and close pilot `mailto:` links, anchors, disclosures,
keyboard focus, footer targets, themes, CSP and no horizontal overflow at
1280/768/390/320px. Desktop and 390px captures in light and dark were inspected.
The page makes no live-provider, coverage, accuracy, cost, customer-acceptance or
deployment claim. [STATUS](./STATUS.md) records delivery state.

## Contact, pilot and legal pages


Checked 8 October 2026 with Ruby 4.0.6, PostgreSQL 16 and Chrome 155.
`bin/rails test`: 727 tests / 11,616 assertions. `bin/rails test test/controllers`:
50 tests / 393 assertions. Landing and lab shell browser tests: 6 tests / 256
assertions. No failures, errors or skips. New
checks cover the pilot and contact `mailto:` hrefs, footer link targets, signed-out
and signed-in Privacy/Terms, Back to top targets and keyboard focus on footer
links. `bin/rubocop`, `zeitwerk:check`, Brakeman and `git diff --check` are clean.
Desktop and 390px captures of the close, footer and both legal pages were
inspected in light and dark: no horizontal overflow or CSP violations. The CSP
initializer is unchanged. A request probe with forgery protection on (as in
production) confirmed the signed-out pages set only the HttpOnly
`_navishai_session` CSRF cookie. Back to top already targeted the existing
`#landing-title`; tests now guard it.
