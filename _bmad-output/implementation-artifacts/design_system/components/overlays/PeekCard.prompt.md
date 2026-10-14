Hover card that opens beside a change after a 450ms rest — enough to decide without opening the inspector.

~~~jsx
<PeekCard id="plkmnvxo" commit="3c4d5e6f" subject="feat(onboarding): swipe gestures + haptic feedback"
  description="Pages can now be swiped; each page change triggers a light haptic." author="Ralph Stein" date="3h"
  files={{ a: 1, m: 3, d: 0 }} added={142} removed={18}
  hint="Click: details · Double-click: jj edit · Drag: onto another change · Right-click: actions"/>
~~~

- 340px, `--bg-elevated`, 1px `--border-strong`, 10px radius, popover shadow; flips left near the right edge.
- The hint line teaches the gestures in the client's exact wording; @ uses "Working copy (@) · Click for details".
- Never opens while dragging, scrolling, or while a menu is up.
