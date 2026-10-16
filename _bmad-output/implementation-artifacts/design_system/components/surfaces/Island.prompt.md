Glass island — the floating container for all chrome over the graph (top-bar groups, rail, inspector); use it instead of docked toolbars.

~~~jsx
<Island shape="bar">
  <GraphSearch />
  <IslandSeparator />
  <IconButton icon="settings" label="View options" />
</Island>
<Island shape="rail" as="nav">…</Island>
<Island shape="panel" style={{ width: 460 }}>…</Island>
~~~

- 12px from the window edge and from each other. Never nest islands; never put a card inside an island.
- Reduce transparency (system, or `data-transparency="reduce"`) and increased contrast turn the glass solid through tokens (`tokens/transparency.css`) — no component rule.
- Keyboard · VoiceOver · Reduce motion: not focusable itself; its controls are, left to right · a group or toolbar labelled by its content · steps aside while the graph scrolls (fade; the drift × `--motion`).
