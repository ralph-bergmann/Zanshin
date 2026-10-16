import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { IconButton } from "../actions/IconButton.jsx";

const ZS_FOCUSABLE = 'button:not([disabled]),[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';

// useSheetFocus — what every modal sheet does with focus (Dialog, ConfirmDialog, PushDialog):
// on open, focus goes to `initial` (a selector inside the sheet) or its first focusable control; Tab and ⇧Tab cycle inside the sheet
// (aria-disabled controls are skipped); on close, focus returns to whatever had it before the sheet opened.
export function useSheetFocus(ref, initial) {
  React.useEffect(() => {
    const el = ref.current; if (!el) return undefined;
    const prev = document.activeElement;
    const list = () => [...el.querySelectorAll(ZS_FOCUSABLE)].filter((n) => n.getAttribute("aria-disabled") !== "true" && n.getClientRects().length);
    const first = (initial && el.querySelector(initial)) || list()[0] || el;
    first.focus({ preventScroll: true });
    const trap = (e) => {
      if (e.key !== "Tab") return;
      const f = list(); if (!f.length) { e.preventDefault(); return; }
      const a = f[0], z = f[f.length - 1];
      if (e.shiftKey && document.activeElement === a) { e.preventDefault(); z.focus(); }
      else if (!e.shiftKey && document.activeElement === z) { e.preventDefault(); a.focus(); }
    };
    el.addEventListener("keydown", trap);
    return () => { el.removeEventListener("keydown", trap); if (prev && prev.focus && document.contains(prev)) prev.focus({ preventScroll: true }); };
  }, []);
}

// Dialog — a modal SHEET over the project window, for short modal tasks (it is not how Settings or Projects open — those are Windows).
// Optional left nav, a toolbar row, a scrolling body. The scrim fills its positioned parent (absolute) — place it inside the window frame.
// Keys and focus: Esc (and the ✕) call onClose — a click on the scrim does nothing: a macOS sheet never closes by a click beside it, and
// unsaved input would be lost without asking. Focus starts on `initialFocus` (or the first control), stays inside, returns.
// closing → the scrim fades and the sheet drops 4px (--dur-exit-lg, --ease-exit); keep it mounted that long (Presence).
export function Dialog({ title, onClose, nav, activeNav, onNav, navHeader, navFooter, tools, width = 900, height = 640, scrim = true, closing = false, initialFocus, className = "", children }) {
  const ref = React.useRef(null);
  useSheetFocus(ref, initialFocus);
  const onKey = (e) => { if (e.key === "Escape" && onClose) { e.preventDefault(); e.stopPropagation(); onClose(); } };
  const box = (
    <div ref={ref} role="dialog" aria-modal="true" aria-label={title} tabIndex={-1} className={["zs-dialog", (nav || navHeader) && "has-nav", className].filter(Boolean).join(" ")}
      style={{ width, height }} onKeyDown={onKey} onClick={(e) => e.stopPropagation()} onMouseDown={(e) => e.stopPropagation()}>
      {(nav || navHeader) && (
        <nav className="zs-dialog-nav">
          {navHeader}
          {nav && (
            <div className="zs-dialog-navlist">
              {nav.map((n) => (
                <button key={n.id} type="button" aria-current={n.id === activeNav ? "page" : undefined} className={"zs-dialog-navitem" + (n.id === activeNav ? " is-on" : "")} onClick={() => onNav && onNav(n.id)}>
                  {n.icon && <Icon name={n.icon} size="md" />}
                  <span>{n.label}</span>
                  {n.count != null && <span className="zs-dialog-navcount">{n.count}</span>}
                </button>
              ))}
            </div>
          )}
          {navFooter && <div className="zs-dialog-navfoot">{navFooter}</div>}
        </nav>
      )}
      <div className="zs-dialog-main">
        <div className="zs-dialog-hd">
          <h2 className="zs-dialog-title">{title}</h2>
          {onClose && <IconButton icon="close" iconSize="sm" label="Close" title="Close (Esc)" size="sm" onClick={onClose} />}
        </div>
        {tools && <div className="zs-dialog-tools">{tools}</div>}
        <div className="zs-dialog-bd">{children}</div>
      </div>
    </div>
  );
  return scrim ? <div className={"zs-scrim" + (closing ? " is-closing" : "")}>{box}</div> : box;
}
