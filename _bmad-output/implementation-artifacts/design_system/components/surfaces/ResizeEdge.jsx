import React from "react";

// ResizeEdge — the grab zone on a floating island's edge toward the graph: the inspector's left edge (side "left": the island lies to its
// right) and a pinned panel's right edge (side "right"), as a Finder or Mail sidebar. Panels clip their content, so the edge is a SIBLING of
// the island in the same positioned container: `at` = the edge's distance from the side the island hangs from (inspector: from the
// right, 12 + its width; panel: from the left), `top` / `bottom` = the island's. The zone is --resize-hit (10) wide — --resize-hit-out (7)
// in the 12px gap, 3 on the island — and runs along the straight part only (the --radius-panel corners left out).
// Hover: the resize cursor at once; after --delay-resize a 2px --edge-hov line fades in on the island's edge; dragging keeps it. At the
// minimum or maximum the cursor shows the one direction left (w-resize / e-resize = AppKit's resizeLeft / resizeRight).
// Drag: live, clamped to min … min(max, limit) — limit keeps --graph-min-w (320) of graph visible. Double-click: back to defaultValue.
// Keyboard (a Tab stop): ← → 10pt (⇧ 50), Home / End = min / max, ↩ = default. role separator with aria-valuenow / -min / -max.
export function ResizeEdge({ side = "left", at = 0, top = 0, bottom = 0, value, min, max, defaultValue, limit, step = 10, label = "Width", onChange, onReset, className = "", style }) {
  const [drag, setDrag] = React.useState(false);
  const hi = Math.max(min, Math.min(max, limit != null ? limit : max));
  const clamp = (v) => Math.round(Math.max(min, Math.min(hi, v)));
  const grow = side === "left" ? -1 : 1; // the pointer direction that widens the island
  const down = (e) => {
    if (e.button !== 0) return;
    e.preventDefault(); e.stopPropagation();
    const x0 = e.clientX, v0 = value, el = e.currentTarget;
    if (el.setPointerCapture) el.setPointerCapture(e.pointerId);
    setDrag(true);
    const mv = (ev) => onChange && onChange(clamp(v0 + (ev.clientX - x0) * grow));
    const up = () => { setDrag(false); el.removeEventListener("pointermove", mv); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up); };
    el.addEventListener("pointermove", mv); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
  };
  const reset = () => { if (onReset) onReset(); else if (onChange && defaultValue != null) onChange(clamp(defaultValue)); };
  const onKey = (e) => {
    const d = e.shiftKey ? step * 5 : step;
    let v = null;
    if (e.key === "ArrowLeft") v = value - grow * d; else if (e.key === "ArrowRight") v = value + grow * d;
    else if (e.key === "Home") v = min; else if (e.key === "End") v = hi;
    else if (e.key === "Enter") { e.preventDefault(); reset(); return; }
    if (v != null) { e.preventDefault(); if (onChange) onChange(clamp(v)); }
  };
  const atMin = value <= min, atMax = value >= hi;
  const cursor = atMin && atMax ? "default" : atMin ? (grow < 0 ? "w-resize" : "e-resize") : atMax ? (grow < 0 ? "e-resize" : "w-resize") : "col-resize";
  const inset = "(var(--resize-hit) - var(--resize-hit-out))";
  const pos = side === "left" ? { right: "calc(" + at + "px - " + inset + ")" } : { left: "calc(" + at + "px - " + inset + ")" };
  return (
    <div role="separator" aria-orientation="vertical" aria-label={label} aria-valuenow={value} aria-valuemin={min} aria-valuemax={hi} aria-valuetext={label + ", " + value + " points"} tabIndex={0}
      className={["zs-resize", "is-" + side, drag && "is-drag", className].filter(Boolean).join(" ")}
      style={{ ...pos, top: "calc(" + top + "px + var(--radius-panel))", bottom: "calc(" + bottom + "px + var(--radius-panel))", cursor, ...style }}
      onPointerDown={down} onDoubleClick={reset} onKeyDown={onKey}></div>
  );
}
