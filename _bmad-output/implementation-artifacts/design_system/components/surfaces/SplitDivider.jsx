import React from "react";

// SplitDivider — the band between two panes of a split that sets the leading pane's length (2026-11-14, Story 10.38, sync #25): the
// inspector's divider between its file list and its diff. axis "x": the panes side by side (a vertical band, col-resize); "y": stacked
// (a horizontal band, row-resize). 12px band; at rest a 4px grip in --fl-border, centred, 10 % of the band's length; on hover and while
// dragging a full-length 2px --accent line. The drag follows the pointer, clamped to min … max (when both cannot hold, max wins: the
// other pane keeps its minimum); double-click and ↩ reset to defaultValue. Keys (a Tab stop): ← → (x) or ↑ ↓ (y) 10px, ⇧ 50px.
// role separator; VoiceOver reads an adjustable slider, its value the leading pane's share of `total` in percent.
export function SplitDivider({ axis = "x", value, min = 0, max = Infinity, defaultValue, total, label = "Files and diff", onChange, onChangeEnd, className = "", style }) {
  const [drag, setDrag] = React.useState(false);
  const clamp = (v) => Math.round(Math.max(0, Math.min(max, Math.max(min, v))));
  const x = axis === "x";
  const down = (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const p0 = x ? e.clientX : e.clientY, v0 = value, el = e.currentTarget;
    let last = v0;
    if (el.setPointerCapture) el.setPointerCapture(e.pointerId);
    setDrag(true);
    const mv = (ev) => { last = clamp(v0 + (x ? ev.clientX : ev.clientY) - p0); if (onChange) onChange(last); };
    const up = () => {
      setDrag(false);
      el.removeEventListener("pointermove", mv); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up);
      if (last !== v0 && onChangeEnd) onChangeEnd(last);
    };
    el.addEventListener("pointermove", mv); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
  };
  const settle = (v) => { const n = clamp(v); if (onChange) onChange(n); if (onChangeEnd) onChangeEnd(n); };
  const onKey = (e) => {
    const d = e.shiftKey ? 50 : 10;
    const less = x ? "ArrowLeft" : "ArrowUp", more = x ? "ArrowRight" : "ArrowDown";
    if (e.key === less) { e.preventDefault(); settle(value - d); }
    else if (e.key === more) { e.preventDefault(); settle(value + d); }
    else if (e.key === "Enter" && defaultValue != null) { e.preventDefault(); settle(defaultValue); }
  };
  const share = total ? Math.round((value / total) * 100) : 0;
  return (
    <div role="separator" aria-orientation={x ? "vertical" : "horizontal"} aria-label={label} aria-valuenow={share} aria-valuemin={0} aria-valuemax={100}
      aria-valuetext={share + "%"} tabIndex={0} title="Drag to resize · double-click to reset"
      className={["zs-split", "is-" + axis, drag && "is-drag", className].filter(Boolean).join(" ")} style={style}
      onPointerDown={down} onDoubleClick={() => defaultValue != null && settle(defaultValue)} onKeyDown={onKey}></div>
  );
}
