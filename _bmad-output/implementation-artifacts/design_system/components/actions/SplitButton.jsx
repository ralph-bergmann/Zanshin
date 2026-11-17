import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Menu } from "../menus/Menu.jsx";

// SplitButton (2026-11-17, Story 10.48) — one shape, two parts: the label runs its command; the divided chevron opens the alternatives.
// Buttons that look the same work the same: a split button runs its label, a MenuButton only opens a menu.
// The shape carries the variant's rest fill and ring (default or primary); each part is its own button (own Tab stop, hover, pressed,
// focus ring inside, disabled) painting its half's step. Click, Space or ↩ on the chevron open the Menu 4px below the button's left
// edge; Esc, a pick or an outside click close it and focus returns to the chevron. `onHighlight` on a row (Menu) lets the caller's
// preview follow the highlighted alternative (the composer's command line and bookmark chips).
export function SplitButton({ label, items = [], onRun, onSelect, variant = "default", size = "md", disabled = false, title,
  menuDisabled = false, menuTitle, menuMaxWidth = 360, mainClassName = "", chevClassName = "", className = "", style }) {
  const wrap = React.useRef(null);
  const chev = React.useRef(null);
  const [open, setOpen] = React.useState(false);
  const [closing, setClosing] = React.useState(false);
  const close = (refocus = true) => {
    setClosing(true);
    setTimeout(() => { setOpen(false); setClosing(false); }, 120);
    if (refocus && chev.current) chev.current.focus();
  };
  React.useEffect(() => {
    if (!open) return;
    const down = (e) => { if (wrap.current && !wrap.current.contains(e.target)) close(false); };
    document.addEventListener("mousedown", down);
    return () => document.removeEventListener("mousedown", down);
  }, [open]);
  const more = "More " + label + " actions";
  return (
    <span ref={wrap} style={style}
      className={["zs-splitbtn", variant === "primary" && "zs-splitbtn--primary", size === "sm" && "zs-splitbtn--sm", className].filter(Boolean).join(" ")}>
      {/* a disabled button takes no hover: its slot carries the reason, as a Menu row's wrapper does */}
      <span className="zs-splitbtn-slot" title={disabled ? title : undefined}>
        <button type="button" className={["zs-splitbtn-part zs-splitbtn-main", mainClassName].filter(Boolean).join(" ")}
          disabled={disabled} title={disabled ? undefined : title} onClick={onRun}>{label}</button>
      </span>
      <span className="zs-splitbtn-div" aria-hidden="true" />
      <span className="zs-splitbtn-slot" title={menuDisabled ? menuTitle : undefined}>
        <button ref={chev} type="button" className={["zs-splitbtn-part zs-splitbtn-chev", chevClassName].filter(Boolean).join(" ")}
          disabled={menuDisabled} title={menuDisabled ? undefined : more} aria-label={more} aria-haspopup="menu" aria-expanded={open}
          onClick={() => (open ? close() : setOpen(true))}><Icon name="chevron-down" size="sm" /></button>
      </span>
      {open && (
        <div className="zs-splitbtn-pop">
          <Menu items={items} autoFocus closing={closing} style={{ maxWidth: menuMaxWidth }}
            onClose={() => close(true)} onSelect={(id, item) => { close(true); onSelect && onSelect(id, item); }} />
        </div>
      )}
    </span>
  );
}
