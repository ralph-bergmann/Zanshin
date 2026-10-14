Right-click / ••• menu for a change; each item names the action and shows the jj command it runs.

~~~jsx
<Menu id="kmnvxoqp" subject="feat(onboarding): swipe gestures" onSelect={run} items={[
  { id: "new", label: "New change on top", icon: "plus", cmd: "jj new" },
  { id: "edit", label: "Edit", icon: "edit", cmd: "jj edit" },
  "sep",
  { id: "abandon", label: "Abandon", icon: "abandon", cmd: "jj abandon", danger: true },
]} />
~~~

- Hover fills with moon (`--accent`); danger items fill red. Mutating items on immutable changes are `disabled`.
