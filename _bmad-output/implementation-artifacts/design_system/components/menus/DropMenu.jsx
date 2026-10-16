import React from "react";
import { Icon } from "../brand/Icon.jsx";

// DropMenu — what can happen when something is dropped on a change. Opens over the target after a short rest.
// items in priority order: [{ id, label, icon, hint (the short jj verb, mono), note (warning instead of hint), group }]
// place "above": the list runs bottom-up so the likeliest action sits nearest the card; the jj command of the active item is the footer.
export function DropMenu({ items = [], active = 0, place = "below", onSelect, onActive, className = "", style }) {
  const order = items.map((a, i) => ({ a, i }));
  const rows = place === "above" ? order.slice().reverse() : order;
  const cur = items[active] || items[0];
  const cmd = cur && cur.cmd ? <div className="zs-drop-cmd" title={cur.cmd}>{cur.cmd}</div> : null;
  return (
    <div role="menu" aria-label="Drop actions" className={["zs-drop", "is-" + place, items.length === 1 && "is-single", className].filter(Boolean).join(" ")} style={style}>
      {place === "below" && cmd}
      <div className="zs-drop-list">
        {rows.map(({ a, i }, k) => (
          <React.Fragment key={a.id}>
            {k > 0 && rows[k - 1].a.group !== a.group && <div className="zs-drop-sep" role="separator"></div>}
            <button type="button" role="menuitem" className={"zs-drop-item" + (i === active ? " is-on" : "")}
              onPointerEnter={() => onActive && onActive(i)} onPointerUp={() => onSelect && onSelect(a.id, i)} onClick={() => onSelect && onSelect(a.id, i)}>
              {a.icon ? <Icon name={a.icon} size="md" /> : <span></span>}
              <span className="zs-drop-l">{a.label}</span>
              {a.note ? <span className="zs-drop-note">{a.note}</span> : <span className="zs-drop-k">{a.hint}</span>}
            </button>
          </React.Fragment>
        ))}
      </div>
      {place === "above" && cmd}
    </div>
  );
}
