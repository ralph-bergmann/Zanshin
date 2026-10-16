import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Menu } from "../menus/Menu.jsx";

// Select — the pop-up button (settings: remotes, trunk; the Configurations dialog's function and mode pickers).
// Trigger: the field's well + value + double chevron. The list is a Menu that opens OVER the trigger (macOS pop-up button):
// · the chosen row lies centred on the trigger and its text starts at the trigger's text x (list left = trigger left − 29);
// · width = trigger + 40, at most 360; clamped 8px inside the window; a list taller than the window minus 16 scrolls, the chosen row in view;
// · it grows out of the chosen row (transform-origin there), --dur-menu on glide; leaving fades (--dur-exit).
// Pointer: a click opens it and it stays; press – drag – release picks the row under the pointer in one gesture.
// Keys: Space ↩ ↑ ↓ open; then the Menu's keys (↑↓ Home End, typeahead — on `text`, so mono <code> labels match too, ↩ picks, Esc closes
// and focus returns to the trigger). placement "below" drops it under the trigger instead (pull-downs that run commands).
// options: ["origin", "sep", { value, label, text, disabled, mono }, { header: "Remote bookmarks" }, { value: "__custom", label: "Custom…" }]
export function Select({ options = [], value, onChange, onCustom, label, mono = false, placement = "over", disabled = false, className = "", style, ...rest }) {
  const wrap = React.useRef(null);
  const btn = React.useRef(null);
  const menu = React.useRef(null);
  const press = React.useRef(null);
  const [open, setOpen] = React.useState(false);
  const [closing, setClosing] = React.useState(false);
  const [pos, setPos] = React.useState(null);
  const opts = options.map((o) => (o === "sep" ? "sep" : typeof o === "string" ? { value: o, label: o } : o));
  const cur = opts.find((o) => o !== "sep" && !o.header && o.value === value);
  const items = opts.map((o) => (o === "sep" ? "sep" : o.header ? { header: o.header } : {
    id: o.value, text: o.text || (typeof o.label === "string" ? o.label : String(o.value)),
    label: mono || o.mono ? <code className="zs-select-code">{o.label}</code> : o.label, checked: o.value === value, radio: true, disabled: o.disabled,
  }));
  const close = (refocus = true) => {
    setClosing(true);
    setTimeout(() => { setOpen(false); setClosing(false); setPos(null); }, 120);
    if (refocus && btn.current) btn.current.focus();
  };
  React.useLayoutEffect(() => {
    if (!open || !menu.current || !wrap.current) return;
    const m = menu.current.querySelector(".zs-menu");
    if (!m) return;
    const w = wrap.current.getBoundingClientRect(), vh = window.innerHeight;
    m.style.maxHeight = vh - 16 + "px"; m.style.overflowY = "auto";
    if (placement === "below") { setPos({ top: w.height + 4, left: 0, origin: "top left" }); return; }
    const row = m.querySelector('.zs-menu-item[aria-checked="true"]') || m.querySelector(".zs-menu-item");
    const rowTop = row ? row.parentElement.offsetTop : 0, h = m.offsetHeight;
    let top = -rowTop + Math.round((w.height - 28) / 2) - 1;
    if (w.top + top < 8) { const over = 8 - (w.top + top); top += over; if (h > vh - 16) m.scrollTop = Math.min(over, m.scrollHeight - h); }
    if (w.top + top + h > vh - 8) top -= w.top + top + h - (vh - 8);
    setPos({ top, left: -29, origin: "29px " + (rowTop - m.scrollTop + 14) + "px" });
  }, [open, placement]);
  React.useEffect(() => {
    if (!open) return;
    const down = (e) => { if (wrap.current && !wrap.current.contains(e.target)) close(false); };
    // press – drag – release: a release over a row after the pointer moved (or after a held press) picks it
    const up = (e) => {
      const p = press.current; press.current = null;
      if (!p) return;
      const moved = Math.abs(e.clientX - p.x) > 4 || Math.abs(e.clientY - p.y) > 4 || Date.now() - p.t > 300;
      const row = e.target.closest && e.target.closest(".zs-menu-item");
      if (moved && row && menu.current && menu.current.contains(row) && !row.disabled) row.click();
    };
    document.addEventListener("mousedown", down);
    document.addEventListener("mouseup", up);
    return () => { document.removeEventListener("mousedown", down); document.removeEventListener("mouseup", up); };
  }, [open]);
  const onKey = (e) => { if (!open && ["ArrowDown", "ArrowUp", " ", "Enter"].includes(e.key)) { e.preventDefault(); setOpen(true); } };
  return (
    <span ref={wrap} className="zs-select-wrap" style={style}>
      <button ref={btn} type="button" className={["zs-select", open && "is-open", className].filter(Boolean).join(" ")} disabled={disabled}
        aria-haspopup="menu" aria-expanded={open} aria-label={label ? label + ": " + (cur ? cur.text || cur.label : "") : undefined}
        onMouseDown={(e) => { if (!open) { e.preventDefault(); press.current = { x: e.clientX, y: e.clientY, t: Date.now() }; setOpen(true); } }} onKeyDown={onKey} {...rest}>
        <span className={"zs-select-v" + (mono || (cur && cur.mono) ? " is-mono" : "")}>{cur ? cur.label : "—"}</span>
        <Icon className="zs-select-chev" name="updown" size="sm" />
      </button>
      {open && (
        <div ref={menu} style={{ position: "absolute", zIndex: "var(--z-menu)", top: pos ? pos.top : 0, left: pos ? pos.left : 0, visibility: pos ? "visible" : "hidden" }}>
          <Menu items={items} autoFocus closing={closing} highlight={items.findIndex((it) => it.checked)}
            style={{ minWidth: (btn.current ? btn.current.offsetWidth : 170) + (placement === "below" ? 0 : 40), maxWidth: 360, transformOrigin: pos ? pos.origin : undefined }}
            onClose={() => close(true)}
            onSelect={(v) => { if (v === "__custom") onCustom && onCustom(); else if (v !== value) onChange && onChange(v); close(true); }} />
        </div>
      )}
    </span>
  );
}
