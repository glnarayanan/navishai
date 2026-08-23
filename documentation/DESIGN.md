# Interface design language

NavishAI uses a quiet, task-first application shell. Warm neutral surfaces keep long work sessions readable. Deep green marks the current path, primary action, focus, and successful state. Red appears only for errors and blocked actions.

## Shared patterns

- The header holds the product mark, current workspace, workspace switcher, and sign-out action.
- Every page has one clear heading and one primary action.
- Forms use visible labels, 12-character password hints, compact controls on desktop, and 48-pixel controls on mobile.
- Flashes announce changes through a shared live region. Form errors appear next to the form and name each problem.
- Empty states explain why the page is empty and offer one next action when the user can take one.
- Tables use row dividers and horizontal overflow rather than shrinking text on narrow screens.

## Accessibility and layout

The shell includes a keyboard skip link, visible focus, semantic landmarks, reduced-motion support, and a 320-pixel minimum layout. Body copy stays at least 16 pixels on mobile. Interactive states must not depend on color alone.
