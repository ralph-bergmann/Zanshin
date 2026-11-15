import React from "react";
import { Button } from "./Button.jsx";
import { Icon } from "../brand/Icon.jsx";
import { Menu } from "../menus/Menu.jsx";

// MenuButton — a Button that opens a Menu (the inspector's Squash: "Squash into parent" · "Absorb into ancestors").
// The Button's look (variant, size, disabled), then chevron-down at 12px, .75 opacity, 5px after the label and 8px before the right edge.
// Click, Space or ↩ open the menu 4px below the button's left edge, or 4px above it when there is no room below (8px from the window's
// edge) and room above (2026-11-15, Story 10.40, as the app's ZsMenuButton); the Menu's keys run it; Esc, a pick, an outside click or a
// click on the open button close it and focus returns to the button. Disabled with a reason: the reason is the wrapper's title.
// iconOnly (2026-11-14, Story 10.33 — the diff header's options): the icon at 14px and the chevron 2px apart, no text, 26px high
// (--control-sm), padding 0 5 0 6; `label` is its name and tooltip; `active` (a value off its default) puts the glyph in --accent.
export function MenuButton({ items = [], onSelect, variant = "default", size = "sm", icon, iconOnly = false, active = false, label, disabled = false, title, menuMaxWidth = 360, children, className = "", style, ...rest }) {
  const wrap = React.useRef(null);
  const pop = React.useRef(null);
  const [open, setOpen] = React.useState(false);
  const [closing, setClosing] = React.useState(false);
  const [up, setUp] = React.useState(false);
  React.useLayoutEffect(() => {
    if (!open) { setUp(false); return; }
    if (!pop.current || !wrap.current) return;
    const h = pop.current.getBoundingClientRect().height, b = wrap.current.getBoundingClientRect();
    setUp(b.bottom + 4 + h > window.innerHeight - 8 && b.top - 4 - h >= 8);
  }, [open]);
  const close = (refocus = true) => {
    setClosing(true);
    setTimeout(() => { setOpen(false); setClosing(false); }, 120);
    const b = wrap.current && wrap.current.querySelector("button");
    if (refocus && b) b.focus();
  };
  React.useEffect(() => {
    if (!open) return;
    const down = (e) => { if (wrap.current && !wrap.current.contains(e.target)) close(false); };
    document.addEventListener("mousedown", down);
    return () => document.removeEventListener("mousedown", down);
  }, [open]);
  return (
    <span ref={wrap} className="zs-menubtn-wrap" style={style} title={disabled ? title : undefined}>
      <Button variant={variant} size={size} icon={iconOnly ? undefined : icon} disabled={disabled} title={disabled ? undefined : iconOnly ? title || label : title}
        aria-label={iconOnly ? label : undefined} aria-haspopup="menu" aria-expanded={open}
        className={["zs-menubtn", iconOnly && "is-icon", iconOnly && active && "is-active", className].filter(Boolean).join(" ")} onClick={() => (open ? close() : setOpen(true))} {...rest}>
        {iconOnly ? <Icon className="zs-menubtn-glyph" name={icon} size="md" /> : children}<Icon className="zs-menubtn-chev" name="chevron-down" size="sm" />
      </Button>
      {open && (
        <div ref={pop} className="zs-menubtn-pop" style={up ? { top: "auto", bottom: "calc(100% + 4px)" } : undefined}>
          <Menu items={items} autoFocus closing={closing} style={{ maxWidth: menuMaxWidth }}
            onClose={() => close(true)} onSelect={(id, item) => { close(true); onSelect && onSelect(id, item); }} />
        </div>
      )}
    </span>
  );
}
