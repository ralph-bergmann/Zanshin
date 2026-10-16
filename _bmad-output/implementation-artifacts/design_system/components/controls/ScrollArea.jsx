import React from "react";

// ScrollArea — the macOS overlay scrollbar, vertical and (axis "both") horizontal. Hidden at rest; shows while scrolling and fades
// --delay-scroll-hide after it stops. Near the edge (the 14px gutter) the track appears and the thumb widens 6 → 10px (--dur-nudge;
// Reduce motion: it is simply wider); dragging darkens it.
// Track click: one page toward the click, as macOS by default ("Jump to the next page"); ⌥-click — or the system setting
// "Jump to the spot that's clicked" (pageJump false) — jumps there. Overscroll is contained (the graph behind never scrolls along);
// the elastic bounce is the platform's.
// Keyboard: the viewport is one Tab stop (focus ring drawn inside); ↑ ↓ ← → 40px · Page Up/Down (and Space / ⇧Space) one page less 40 ·
// Home / End to the ends. VoiceOver: a scroll area; the bars are decoration (aria-hidden) — VO scrolls with its own commands.
export function ScrollArea({ height = 240, axis = "y", pageJump = true, label, children, className = "", style }) {
  const vp = React.useRef(null);
  const hide = React.useRef(0);
  const [bar, setBar] = React.useState({ top: 0, h: 0, left: 0, w: 0 });
  const [show, setShow] = React.useState(false);
  const [hover, setHover] = React.useState(null);
  const [drag, setDrag] = React.useState(null);
  const measure = React.useCallback(() => {
    const el = vp.current;
    if (!el) return;
    const my = el.scrollHeight - el.clientHeight, mx = el.scrollWidth - el.clientWidth;
    const h = my > 0 ? Math.max(24, (el.clientHeight - 4) * (el.clientHeight / el.scrollHeight)) : 0;
    const w = axis !== "y" && mx > 0 ? Math.max(24, (el.clientWidth - 4) * (el.clientWidth / el.scrollWidth)) : 0;
    setBar({ h, top: h ? (el.scrollTop / my) * (el.clientHeight - 4 - h) : 0, w, left: w ? (el.scrollLeft / mx) * (el.clientWidth - 4 - w) : 0 });
  }, [axis]);
  React.useEffect(() => { measure(); }, [measure, children]);
  const ms = () => { const n = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--delay-scroll-hide")); return isNaN(n) ? 800 : n; };
  const onScroll = () => { measure(); setShow(true); clearTimeout(hide.current); hide.current = setTimeout(() => setShow(false), ms()); };
  const onMove = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    setHover(r.right - e.clientX <= 14 ? "y" : axis !== "y" && r.bottom - e.clientY <= 14 ? "x" : null);
  };
  const startDrag = (dir) => (e) => {
    e.preventDefault(); e.stopPropagation();
    const el = vp.current, p0 = dir === "y" ? e.clientY : e.clientX, s0 = dir === "y" ? el.scrollTop : el.scrollLeft;
    const k = dir === "y" ? (el.scrollHeight - el.clientHeight) / (el.clientHeight - 4 - bar.h) : (el.scrollWidth - el.clientWidth) / (el.clientWidth - 4 - bar.w);
    setDrag(dir);
    const mv = (ev) => { const d = ((dir === "y" ? ev.clientY : ev.clientX) - p0) * k; if (dir === "y") el.scrollTop = s0 + d; else el.scrollLeft = s0 + d; };
    const up = () => { setDrag(null); window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", mv);
    window.addEventListener("pointerup", up);
  };
  const trackClick = (dir) => (e) => {
    const el = vp.current, r = e.currentTarget.getBoundingClientRect();
    const spot = !pageJump !== !e.altKey; // ⌥ inverts the system setting
    if (dir === "y") {
      const y = e.clientY - r.top, page = el.clientHeight - 40;
      if (spot) el.scrollTop = (y / r.height) * (el.scrollHeight - el.clientHeight); else el.scrollTop += y < bar.top ? -page : page;
    } else {
      const x = e.clientX - r.left, page = el.clientWidth - 40;
      if (spot) el.scrollLeft = (x / r.width) * (el.scrollWidth - el.clientWidth); else el.scrollLeft += x < bar.left ? -page : page;
    }
  };
  const onKey = (e) => {
    const el = vp.current, page = el.clientHeight - 40;
    const moves = { ArrowDown: [0, 40], ArrowUp: [0, -40], ArrowRight: [40, 0], ArrowLeft: [-40, 0], PageDown: [0, page], PageUp: [0, -page], " ": [0, e.shiftKey ? -page : page] };
    if (e.target !== el) return;
    if (moves[e.key]) { e.preventDefault(); el.scrollBy(moves[e.key][0], moves[e.key][1]); }
    else if (e.key === "Home") { e.preventDefault(); el.scrollTop = 0; }
    else if (e.key === "End") { e.preventDefault(); el.scrollTop = el.scrollHeight; }
  };
  const cls = ["zs-scroll", show && "is-show", hover === "y" && "is-hover", hover === "x" && "is-hover-x", drag === "y" && "is-drag", drag === "x" && "is-drag-x", className].filter(Boolean).join(" ");
  return (
    <div className={cls} style={{ height, ...style }} onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
      <div ref={vp} className="zs-scroll-vp" onScroll={onScroll} onKeyDown={onKey} tabIndex={0} role="region" aria-label={label}
        style={axis === "y" ? { overflowX: "hidden" } : undefined}>{children}</div>
      {bar.h > 0 && (
        <div className="zs-scroll-bar" aria-hidden="true" onPointerDown={trackClick("y")}>
          <div className="zs-scroll-thumb" style={{ height: bar.h, transform: "translateY(" + bar.top + "px)" }} onPointerDown={startDrag("y")}></div>
        </div>
      )}
      {bar.w > 0 && (
        <div className="zs-scroll-bar is-x" aria-hidden="true" onPointerDown={trackClick("x")}>
          <div className="zs-scroll-thumb" style={{ width: bar.w, transform: "translateX(" + bar.left + "px)" }} onPointerDown={startDrag("x")}></div>
        </div>
      )}
    </div>
  );
}
