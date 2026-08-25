# Interface design language

NavishAI uses a quiet operational shell with the same visual language as the public product page: cool paper surfaces, near-black Geist type, and electric blue for the current path, primary action, and focus. Red is reserved for errors, blocked work, and destructive confirmation. Success is a distinct green; warnings are amber. Informational, review-required, blocked, and degraded states also use a distinct icon and label, not color alone.

Geist and Geist Mono are hosted from `app/assets/fonts` under the SIL Open Font License. They are not loaded from a CDN or font service.

Light and dark themes share one token set. The interface follows the operating-system preference until a person chooses Light, Dark, or System, and that choice persists across visits.

## Shared patterns

- Authenticated work uses a persistent sidebar grouped by operating intent: Work, Knowledge and intelligence, Agent operations, Channels, and Workspace administration. Workspace identity lives in the sidebar header; theme, sign-out, and notifications live in a quiet footer. Notifications show a count only when something is unread. Destinations keep visible text labels and a matching local icon.
- A compact page bar holds location, the current section title, status, and page-specific actions. It does not repeat global navigation.
- On tablet and mobile, including a 1024-pixel viewport, the destinations move into an accessible drawer. The mobile app bar stays under 88 pixels so the current page is in the first viewport. Internal grids follow available canvas width so a 1024-pixel canvas never keeps a full desktop three-column workbench.
- Page families stay distinct: scannable collections, focused record workspaces, staged configuration, integration setup, and admin or data controls. Setup forms stay behind a disclosure until requested; the page leads with status the workspace already has.
- Cases keep a compact queue, a conversation and investigation column, and a decision rail. Draft, evidence, memory, crew progress, policy review, and the human-send gate sit above history. Customer metadata, tags, notes, priority, assignment, and audit history sit behind disclosures. Next action and status changes stay visible.
- The scorecard is a staged flow: one editable stage is open at a time, with a compact current-proposal summary and a rail for published state, preview actions, publish, and history. Comparison tables scroll when they exceed available width; mobile uses labeled stacked rows.
- Every page has one clear heading and one primary action.
- Forms use visible labels, grouping, nearby validation, 12-character password hints, compact controls on desktop, and 48-pixel controls on mobile.
- Flashes announce changes through a shared live region. Form errors appear next to the form and name each problem.
- Empty, blocked, degraded, loading, and permission states explain what happened and offer a next action when one exists.
- Tables use row dividers and horizontal overflow rather than shrinking text on narrow screens.
- Motion is short and mechanical: header compression, progress lines, and staged demos. It stops under `prefers-reduced-motion`.

## Accessibility and layout

The shell includes a keyboard skip link, visible focus, semantic landmarks, reduced-motion support, and a 320-pixel minimum layout. Body copy stays at least 16 pixels on mobile. Interactive states must not depend on color alone.
