A change in the graph — the product's core object; place cards on the canvas (absolute) and connect them with GraphEdge.

~~~jsx
<ChangeCard id="ovknlmro" workingCopy empty />
<ChangeCard id="plkmnvxo" subject="feat(onboarding): swipe gestures" author="Ralph" date="3h" bookmarks={["feature/ZAN-412_onboarding-swipe-gestures", "ZAN-412@origin"]} />
<ChangeCard id="wlyrtqpz" subject="Release 2.4.0" immutable detailed={false} />
~~~

- 240 × 62 (detailed) / 40 (compact); cards sit 56px apart horizontally, 48px vertically; parents below, children above.
- Click = select (moon ring) · double-click = `jj edit` · drag onto another card = `jj rebase`.
- **Immutable** (`immutable`): the normal card with a 135° hatch, 1px every 6px in `--hatch` (7% of `--text`) — kept on hover, selection, open menu and drop target; stacks follow (`StackCard immutable`). The subject stays `--text-muted`. **No colour and no ◆** — the hatch is the marker; where the word is written, `HatchSwatch` names it (peek, card menu, inspector, Settings). Double-click does nothing there (no `jj edit`), and the peek's hint leaves it out.
- Keyboard · VoiceOver · Reduce motion: a Tab stop in the graph; ↩ selects (opens the inspector), ⌥↩ / ⇧F10 the actions menu, arrow keys move to the parent / child / neighbour · button "Working copy, feat(onboarding)…" (with workspaces: "working copy of default; also ci") · re-layout jumps (FLIP → 0), a new change fades in, the edit flash stays.
