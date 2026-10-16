The inspector and the pinned panels (Bookmarks, Undo Timeline, Reviews) are resizable at **their edge toward the graph** — the inspector at its left edge, the panels at their right — as a sidebar in Finder or Mail. `ResizeEdge` is that edge.

~~~jsx
<ResizeEdge side="left" at={12 + insW} top={60} bottom={12} value={insW} min={380} max={720} defaultValue={460}
  limit={window.innerWidth - leftInset - 24 - 320} label="Inspector width" onChange={setInsW}/>
<ResizeEdge side="right" at={76 + panW} top={60} bottom={12} value={panW} min={240} max={440} defaultValue={300} label="Panel width" onChange={setPanW}/>
~~~

- **Grab zone:** 10pt wide (`--resize-hit`) on the island's edge — 7 in the 12pt gap (`--resize-hit-out`), 3 over the island — along the straight part of the edge only (the 16pt corners left out). A sibling of the island (panels clip their content), placed with `at` / `top` / `bottom`.
- **Hover and drag:** the resize cursor at once (`col-resize`; at the minimum or maximum the one direction left — AppKit's resizeLeft / resizeRight); after `--delay-resize` (150) a **2pt line in `--edge-hov`** fades in on the island's edge (`--dur-hover`) — no glow, no accent: it is a handle, not a selection. While dragging the line stays.
- **Widths are tokens:** `--inspector-w` 460 (`-min` 380 · `-max` 720) · `--panel-w` 300 (`-min` 240 · `-max` 440); 460 and 300 stay the defaults. One width for the inspector, one shared by all left panels, **remembered app-wide**.
- **Behaviour:** double-click on the edge = the default width. While dragging, the graph's edge follows live and the cards stay where they are (as when a panel is pinned). **The window:** at least `--graph-min-w` (320) of graph stays visible — a drag stops there (`limit`). When the window gets narrower, the island first shrinks to its minimum (the inspector before a pinned panel), and only then the panel detaches (floats over the graph) — it comes back at its remembered width once there is room.
- Keyboard · VoiceOver · Reduce motion: a Tab stop (after the island's own controls); ← → change the width by 10pt (⇧: 50), Home / End go to the minimum / maximum, ↩ to the default — so the width never needs a mouse · `role="separator"`, vertical, with value, minimum and maximum: VoiceOver reads "Inspector width, 460 points, splitter" and VO-← / → adjust it · a drag follows the pointer with no tween; the double-click reset changes the width on `--dur-expand` (a movement token: under Reduce motion it jumps).
