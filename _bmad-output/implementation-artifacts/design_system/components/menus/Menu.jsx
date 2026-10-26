import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { ChangeId } from "../graph/ChangeId.jsx";
import { AtBadge } from "../graph/AtBadge.jsx";

// reads a motion token (ms) so code and tokens never drift; falls back where there is no document
export const zsMs = (name, fallback) => { try { const n = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name)); return isNaN(n) ? fallback : n; } catch (e) { return fallback; } };
const zsActionable = (it) => it && it !== "sep" && !it.header && !it.note && !it.disabled;
const zsText = (it) => (it.text != null ? it.text : typeof it.label === "string" ? it.label : "").toLowerCase();
// is p inside the triangle a → b → c (the pointer's last spot and the submenu's near corners)?
const zsInTri = (p, a, b, c) => { const s = (u, v, w) => (u.x - w.x) * (v.y - w.y) - (v.x - w.x) * (u.y - w.y); const d1 = s(p, a, b), d2 = s(p, b, c), d3 = s(p, c, a); return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0)); };

// Menu — every command menu: actions on a change (head names it, rows show the jj command), the text context menu, pull-downs,
// the project menu, the Select list. items: [{ id, label, text, icon, cmd, shortcut, danger, disabled, checked, radio, submenu, title }]
// · "sep" · { header }. `text` is what typeahead matches when the label is a node (mono <code>, a project row).
// One highlight shared by mouse and keyboard (solid accent + ink; danger rows a red tint). Keyboard: ↑/↓ move (wrap), Home/End,
// typing jumps (letters within --dur-typeahead extend the match), Return/Space activate, → opens a submenu, ← closes it, Esc closes.
// Activation blinks the row (off --dur-blink · on --dur-blink), then onSelect; the parent closes the menu with its exit (closing).
// Submenus: open after --delay-submenu on hover (at once with → ↩ or a click); while the pointer travels toward an open submenu
// (inside the triangle from where it was to the submenu's near corners) other rows don't take the highlight; the submenu closes
// --delay-submenu-out after the pointer leaves row and triangle. It opens to the right, flips left when the window has no room
// (8px margin) and shifts up to stay 8px inside the bottom edge.
export function Menu({ id, subject, workingCopy = false, items = [], onSelect, onClose, autoFocus = false, blink = true, highlight, closing = false, still = false, className = "", style, ...rest }) {
  const ref = React.useRef(null);
  const uid = React.useId();
  // note rows (why something is missing) aren't commands: the keyboard skips them, the menu points at them for VoiceOver
  const notes = items.map((it, i) => (it && it.note ? uid + "-n" + i : null)).filter(Boolean).join(" ");
  const [hi, setHi] = React.useState(highlight == null ? -1 : highlight);
  const [kbd, setKbd] = React.useState(false);
  const [blinkAt, setBlinkAt] = React.useState(-1);
  const [sub, setSub] = React.useState(-1);
  const busy = React.useRef(false);
  const typed = React.useRef({ s: "", t: 0 });
  const subT = React.useRef(0), last = React.useRef(null), subEl = React.useRef(null);
  React.useEffect(() => { if (highlight != null) setHi(highlight); }, [highlight]);
  React.useEffect(() => { if (autoFocus && ref.current) ref.current.focus({ preventScroll: true }); }, [autoFocus]);
  React.useEffect(() => () => clearTimeout(subT.current), []);
  const step = (from, dir) => {
    for (let k = 1; k <= items.length; k++) { const j = (((from + dir * k) % items.length) + items.length) % items.length; if (zsActionable(items[j])) return j; }
    return from;
  };
  const activate = (i) => {
    const it = items[i];
    if (!zsActionable(it) || busy.current) return;
    if (it.submenu) { clearTimeout(subT.current); setSub(i); return; }
    if (!blink) { onSelect && onSelect(it.id, it); return; }
    const ms = zsMs("--dur-blink", 70);
    busy.current = true; setHi(i); setBlinkAt(i);
    setTimeout(() => { setBlinkAt(-1); setTimeout(() => { busy.current = false; onSelect && onSelect(it.id, it); }, ms); }, ms);
  };
  const aiming = (e) => {
    const box = subEl.current && subEl.current.getBoundingClientRect(), p = last.current;
    if (!box || !p) return false;
    const nearX = box.left >= p.x ? box.left : box.right;
    return zsInTri({ x: e.clientX, y: e.clientY }, p, { x: nearX, y: box.top }, { x: nearX, y: box.bottom });
  };
  const enter = (i, e) => {
    if (busy.current) return;
    const it = items[i];
    clearTimeout(subT.current);
    if (sub >= 0 && sub !== i && aiming(e)) { subT.current = setTimeout(() => { setHi(i); setSub(it.submenu ? i : -1); }, zsMs("--delay-submenu-out", 300)); return; }
    setHi(i);
    if (it.submenu) subT.current = setTimeout(() => setSub(i), zsMs("--delay-submenu", 150));
    else if (sub >= 0) subT.current = setTimeout(() => setSub(-1), zsMs("--delay-submenu-out", 300));
  };
  const onKey = (e) => {
    const k = e.key;
    if (k === "ArrowDown" || k === "ArrowUp") { e.preventDefault(); setKbd(true); setSub(-1); setHi((h) => step(h < 0 && k === "ArrowUp" ? 0 : h, k === "ArrowDown" ? 1 : -1)); }
    else if (k === "Home" || k === "End") { e.preventDefault(); setKbd(true); setHi(k === "Home" ? step(-1, 1) : step(items.length, -1)); }
    else if (k === "Enter" || k === " ") { e.preventDefault(); activate(hi); }
    else if (k === "ArrowRight") { if (items[hi] && items[hi].submenu) { e.preventDefault(); setKbd(true); setSub(hi); } }
    else if (k === "ArrowLeft" || k === "Escape") { e.preventDefault(); e.stopPropagation(); onClose && onClose(); }
    else if (k.length === 1 && /\S/.test(k)) {
      const now = Date.now(); const t = typed.current;
      t.s = now - t.t < zsMs("--dur-typeahead", 600) ? t.s + k.toLowerCase() : k.toLowerCase(); t.t = now;
      const from = Math.max(0, t.s.length > 1 ? hi : hi + 1);
      for (let n = 0; n < items.length; n++) {
        const j = (from + n) % items.length;
        if (zsActionable(items[j]) && zsText(items[j]).startsWith(t.s)) { setKbd(true); setHi(j); break; }
      }
    }
  };
  const cls = ["zs-menu", kbd && "is-kbd", closing && "is-closing", still && "is-static", className].filter(Boolean).join(" ");
  return (
    <div ref={ref} role="menu" tabIndex={-1} aria-label={subject} aria-describedby={notes || undefined} className={cls} style={style} onKeyDown={onKey}
      onMouseMove={(e) => { if (kbd) setKbd(false); if (sub < 0 || !aiming(e)) last.current = { x: e.clientX, y: e.clientY }; }}
      onMouseLeave={() => { if (!kbd && sub < 0 && !busy.current) setHi(-1); }} {...rest}>
      {(id || subject) && (
        <div className="zs-menu-head">
          {workingCopy && <AtBadge size="sm" />}
          {id && <ChangeId id={id} length={8} />}
          {subject && <span className="zs-menu-subj">{subject}</span>}
        </div>
      )}
      {items.map((it, i) => {
        if (it === "sep") return <div key={"sep" + i} className="zs-menu-sep" role="separator"></div>;
        if (it.header) return <div key={"h" + i} className="zs-menu-h" role="presentation">{it.header}</div>;
        if (it.note) return <div key={"n" + i} id={uid + "-n" + i} className="zs-menu-note">{typeof it.icon === "string" ? <Icon name={it.icon} size="sm" /> : it.icon || <span></span>}<span>{it.note}</span></div>;
        const check = it.checked !== undefined;
        const cls = ["zs-menu-item", it.danger && "is-danger", i === hi && "is-hi", i === blinkAt && "is-blink"].filter(Boolean).join(" ");
        return (
          <div key={it.id || i} className="zs-menu-row" style={{ position: "relative" }} title={it.disabled ? it.title : undefined}>
            <button type="button" tabIndex={-1} className={cls} disabled={it.disabled} title={it.disabled ? undefined : it.title}
              role={check ? (it.radio ? "menuitemradio" : "menuitemcheckbox") : "menuitem"} aria-checked={check ? !!it.checked : undefined}
              aria-haspopup={it.submenu ? "menu" : undefined} aria-expanded={it.submenu ? sub === i : undefined}
              onMouseEnter={(e) => enter(i, e)} onClick={() => activate(i)}>
              {check ? <span className="zs-menu-chk">{it.checked && <Icon name="check" size="sm" />}</span> : typeof it.icon === "string" ? <Icon name={it.icon} size="md" /> : it.icon || <span></span>}
              <span className="zs-menu-l">{it.label}</span>
              <span className="zs-menu-r">
                {it.cmd && <span className="zs-menu-cmd">{it.cmd}</span>}
                {it.shortcut && <span className="zs-menu-sc">{it.shortcut}</span>}
                {it.submenu && <Icon className="zs-menu-chev" name="chevron-right" size="sm" />}
              </span>
            </button>
            {it.submenu && sub === i && (
              <ZsSubmenu subRef={subEl} items={it.submenu} kbd={kbd} blink={blink} onSelect={onSelect}
                onClose={() => { setSub(-1); ref.current && ref.current.focus(); }} />
            )}
          </div>
        );
      })}
    </div>
  );
}

// the submenu places itself: right of its row, flipped left without room, shifted up to stay 8px inside the window
function ZsSubmenu({ subRef, items, kbd, blink, onSelect, onClose }) {
  const box = React.useRef(null);
  const [pos, setPos] = React.useState({ flip: false, dy: 0 });
  React.useLayoutEffect(() => {
    const el = box.current && box.current.firstElementChild; if (!el) return;
    subRef.current = el;
    const r = el.getBoundingClientRect(), W = window.innerWidth, H = window.innerHeight;
    setPos({ flip: r.right > W - 8, dy: r.bottom > H - 8 ? Math.min(r.top - 8, r.bottom - (H - 8)) : 0 });
    return () => { subRef.current = null; };
  }, []);
  return (
    <div ref={box} className={"zs-menu-subwrap" + (pos.flip ? " is-flip" : "")} style={{ transform: pos.dy ? "translateY(" + -pos.dy + "px)" : undefined }}>
      <Menu items={items} className="zs-menu-sub" autoFocus={kbd} blink={blink} onSelect={onSelect} onClose={onClose} />
    </div>
  );
}
