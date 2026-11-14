The band between two panes of a split — the inspector's divider between its file list and its diff (2026-11-14, Story 10.38, sync #25). `ResizeEdge` resizes an island at its edge toward the graph; `SplitDivider` divides the inside of one.

~~~jsx
<div style={{ display: "flex", flexDirection: wide ? "row" : "column" }}>
  <Files style={{ flex: "0 0 " + files + "px" }}/>
  <SplitDivider axis={wide ? "x" : "y"} value={files} min={wide ? 220 : 110} max={room - (wide ? 320 : 140)} total={room}
    defaultValue={room * (wide ? .34 : .38)} onChange={setFiles} onChangeEnd={(v) => remember(wide, v / room)}/>
  <Diff style={{ flex: 1 }}/>
</div>
~~~

- **Look:** a 12px band. At rest a 4px grip in `--fl-border`, centred, 10 % of the band's length; on hover and while dragging a full-length 2px `--accent` line. Cursor `col-resize` (side by side) or `row-resize` (stacked).
- **Behaviour:** the drag follows the pointer; double-click (and ↩) resets to the default. Minimums: files 110 / 220, diff 140 / 320 (stacked / side by side); when both cannot fit the diff's minimum wins. The files' share is remembered per layout, app-wide (defaults .38 stacked, .34 side by side) — written when a drag ends or on reset, never per move.
- **The inspector's layout** follows its width: side by side from 780pt, stacked below 740; between the two the last layout stays (no flip-flop at the threshold).
- Keyboard · VoiceOver · Reduce motion: a Tab stop with the ring; ← → (side by side) or ↑ ↓ (stacked) move 10pt, ⇧ 50pt; ↩ resets · an adjustable slider named "Files and diff", its value the files' share in percent · no animation.
