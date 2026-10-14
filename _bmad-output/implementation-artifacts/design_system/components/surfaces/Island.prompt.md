Glass island — the floating container for all chrome over the graph (top-bar groups, rail, inspector); use it instead of docked toolbars.

~~~jsx
<Island shape="bar">
  <CommandField command="jj log -r 'trunk()..@'" />
  <IslandSeparator />
  <IconButton icon="settings" label="View options" />
</Island>
<Island shape="rail" as="nav">…</Island>
<Island shape="panel" style={{ width: 460 }}>…</Island>
~~~

- 12px from the window edge and from each other. Never nest islands; never put a card inside an island.
- `data-material="solid"` on an ancestor swaps glass for the opaque surface.
