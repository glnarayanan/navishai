# Interface design language

NavishAI uses the licensed MagicUI agent-template composition as the executable visual specification. Product content and behaviour are NavishAI; the visible geometry is not reinterpreted. Surfaces share cool paper, near-black Geist type, and electric blue (`--secondary`) for the current path, primary action, and focus. Red is reserved for errors, blocked work, and destructive confirmation. Success is green; warnings are amber. Informational, review-required, blocked, and degraded states also use a distinct icon and label, not color alone.

Geist and Geist Mono are hosted from `app/assets/fonts` under the SIL Open Font License. They are not loaded from a CDN or font service.

Light and dark themes share one token set. The interface follows the operating-system preference until a person chooses Light, Dark, or System, and that choice persists across visits.

## Visual grammar

- Navigation and meta: 14px. Body: 16px with comfortable line height. Card titles: 18–20px. Page titles: 28–32px, tightly tracked.
- Radii: 10px fields and compact cards, 12px sheets, 16px major cards. Hairline borders, layered light/dark surfaces, restrained shadows.
- Icons are local 16/20px SVG. Spacing follows an 8/12/16/24 rhythm.
- Motion is 150–300ms CSS or Stimulus. It stops under `prefers-reduced-motion`.

## Public product page

The landing page retains the template section rhythm: sticky header contracting on scroll, centered active-nav pill, icon-only theme control, a content-fitted product preview in place of the 16:9 media stage, bordered proof grid, a static four-step support workflow, customer-outcome cards, quote band, two-panel self-hosting visual, FAQ, CTA with supplied artwork, and a large NavishAI footer sign-off. The template's pricing and testimonial sections are omitted until NavishAI has either. Sign in lives in the mobile drawer. The workflow uses one ordered sequence across desktop and mobile, with its full explanations and illustrations available without JavaScript.

## Authenticated shell

- Work sits in a bounded, layered frame on a radial wash. Destinations are 40–44px pills with visible text and a matching local icon.
- Workspace identity lives in the sidebar header; theme, sign-out, and notifications live in a contained footer.
- A compact floating page bar holds location, the current section title, status, and page-specific actions.
- On tablet and mobile, including a 1024-pixel viewport, destinations move into an approximately 95%-wide bottom sheet with a cyclic focus trap, Escape, and focus restoration. The mobile app bar stays under 88 pixels.

## Page families

- Cases keep a compact queue, conversation and investigation, and a decision rail. The primary next action is blue; secondary controls stay quiet.
- Accounts put current health in the mobile first fold. Signals use a table on desktop and keyboard-reachable cards on mobile, keeping signal, value, source/range, weight, risk points, and citation.
- The scorecard is a visual scoring workspace: comparison first, compact threshold cards, and progressive disclosure for history, backtest, publish, and validation. Constrained AI proposals sit above the manual designer, show inspectable diffs when revised, and never publish on generate. Mobile preserves Account/Published/Proposal/Change.
- Memory uses provenance and state cards with light/dark layer separation.
- Setup, auth, and admin routes have route-specific compositions. Setup forms stay behind a disclosure until requested.

## Accessibility and layout

The shell includes a keyboard skip link, visible focus, semantic landmarks, reduced-motion support, and a 320-pixel minimum layout. Body copy stays at least 16 pixels on mobile. Interactive states must not depend on color alone. CSP remains `style-src 'self'` without DOM prototype monkey-patches.
