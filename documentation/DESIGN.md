# Interface design language

NavishAI uses a quiet operational shell with the same visual language as the public product page: cool paper surfaces, near-black Geist type, and electric blue for the current path, primary action, and focus. Red is reserved for errors, blocked work, and destructive confirmation. Success is a distinct green; warnings are amber. Informational, review-required, blocked, and degraded states also use a distinct icon and label, not color alone.

Light and dark themes share one token set. The interface follows the operating-system preference until a person chooses Light, Dark, or System, and that choice persists across visits.

## Shared patterns

- Authenticated work uses a persistent sidebar grouped by operating intent. Workspace identity lives in the sidebar header; theme, sign-out, and notifications live in a quiet footer. Notifications show a count only when something is unread.
- A compact page bar holds location, status, and page-specific actions. It does not repeat global navigation.
- On tablet and mobile the destinations move into an accessible drawer. The mobile app bar stays under 88 pixels so the current page is in the first viewport.
- Every page has one clear heading and one primary action.
- Forms use visible labels, 12-character password hints, compact controls on desktop, and 48-pixel controls on mobile.
- Flashes announce changes through a shared live region. Form errors appear next to the form and name each problem.
- Empty, blocked, degraded, loading, and permission states explain what happened and offer a next action when one exists.
- Tables use row dividers and horizontal overflow rather than shrinking text on narrow screens.
- Motion is short and mechanical: header compression, progress lines, and staged demos. It stops under `prefers-reduced-motion`.

## Accessibility and layout

The shell includes a keyboard skip link, visible focus, semantic landmarks, reduced-motion support, and a 320-pixel minimum layout. Body copy stays at least 16 pixels on mobile. Interactive states must not depend on color alone.
