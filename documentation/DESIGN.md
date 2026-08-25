# Interface design language

NavishAI uses a quiet operational shell with the same visual language as the public product page: cool paper surfaces, near-black type, and electric blue for the current path, primary action, and focus. Red is reserved for errors, blocked work, and destructive confirmation. Success is a distinct green; warnings are amber.

Light and dark themes share one token set. The interface follows the operating-system preference until a person chooses Light, Dark, or System, and that choice persists across visits.

## Shared patterns

- The header holds the product mark, current workspace, primary destinations, theme control, and sign-out.
- Every page has one clear heading and one primary action.
- Forms use visible labels, 12-character password hints, compact controls on desktop, and 48-pixel controls on mobile.
- Flashes announce changes through a shared live region. Form errors appear next to the form and name each problem.
- Empty, blocked, degraded, loading, and permission states explain what happened and offer a next action when one exists.
- Tables use row dividers and horizontal overflow rather than shrinking text on narrow screens.
- Motion is short and mechanical: header compression, progress lines, and staged demos. It stops under `prefers-reduced-motion`.

## Accessibility and layout

The shell includes a keyboard skip link, visible focus, semantic landmarks, reduced-motion support, and a 320-pixel minimum layout. Body copy stays at least 16 pixels on mobile. Interactive states must not depend on color alone.
