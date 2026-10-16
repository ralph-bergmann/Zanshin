import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Disclosure — a chevron row that opens a section. The chevron turns 0 → 90° and the body's height animates (--dur-panel, glide).
// Keyboard: Space/↩ toggle, → opens, ← closes (as in the Projects tree).
export function Disclosure({ label, open: openProp, defaultOpen = false, onToggle, meta, children, className = "" }) {
  const [own, setOwn] = React.useState(defaultOpen);
  const open = openProp != null ? openProp : own;
  const body = React.useRef(null);
  const first = React.useRef(true);
  React.useLayoutEffect(() => {
    const el = body.current;
    if (!el) return;
    if (first.current) { first.current = false; el.style.height = open ? "auto" : "0px"; return; }
    const from = el.getBoundingClientRect().height;
    el.style.height = "auto";
    const to = open ? el.scrollHeight : 0;
    el.style.height = from + "px";
    void el.offsetHeight;
    el.style.height = to + "px";
    const instant = parseFloat(getComputedStyle(el).transitionDuration) === 0;
    if (instant) { if (open) el.style.height = "auto"; return; }
    const done = (e) => { if (e.target === el && e.propertyName === "height") { if (open) el.style.height = "auto"; el.removeEventListener("transitionend", done); } };
    el.addEventListener("transitionend", done);
    return () => el.removeEventListener("transitionend", done);
  }, [open]);
  const set = (v) => { setOwn(v); onToggle && onToggle(v); };
  return (
    <div className={["zs-disc", open && "is-open", className].filter(Boolean).join(" ")}>
      <button type="button" className="zs-disc-hd" aria-expanded={open} onClick={() => set(!open)}
        onKeyDown={(e) => { if (e.key === "ArrowRight" && !open) { e.preventDefault(); set(true); } else if (e.key === "ArrowLeft" && open) { e.preventDefault(); set(false); } }}>
        <Icon name="chevron-right" size="sm" className="zs-disc-chev" />
        <span className="zs-disc-l">{label}</span>
        {meta != null && <span className="zs-disc-meta">{meta}</span>}
      </button>
      <div ref={body} className="zs-disc-bd" aria-hidden={!open}>{children}</div>
    </div>
  );
}
