Hover card that opens beside a change after a 450ms rest — enough to decide without opening the inspector.

~~~jsx
<PeekCard id="plkmnvxo" commit="3c4d5e6f" subject="feat(onboarding): swipe gestures + haptic feedback"
  description="Pages can now be swiped; each page change triggers a light haptic." author="Ralph Stein" date="3h"
  files={{ a: 1, m: 3, d: 0 }} added={142} removed={18}
  hint="Click: details · Double-click: jj edit · Drag: onto another change · Right-click: actions"/>
~~~

- 340px on the one menu material (`--fl-sheen` over `--fl-bg-solid`, 1px `--fl-border`, radius 13, `--shadow-menu`); flips left near the right edge; opens after `--delay-peek` (450ms; a stack's list after `--delay-stack-list`, 380ms).
- The hint line teaches the gestures in the client's exact wording; @ uses "Working copy (@) · Click for details".
- Never opens while dragging, scrolling, or while a menu is up.
- Keyboard · VoiceOver · Reduce motion: hover-only (after `--delay-peek`); keyboard users get the same facts in the inspector · not announced · fades in.
