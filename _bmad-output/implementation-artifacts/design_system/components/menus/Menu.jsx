import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { ChangeId } from "../graph/ChangeId.jsx";
import { AtBadge } from "../graph/AtBadge.jsx";

// Menu — actions on one change. Head names the change; every item shows the jj command it runs.
// items: [{ id, label, icon, cmd, danger, disabled }] — use "sep" for a separator.
export function Menu({ id, subject, workingCopy = false, items = [], onSelect, className = "", style, ...rest }) {
  return (
    <div role="menu" className={("zs-menu " + className).trim()} style={style} {...rest}>
      {(id || subject) && (
        <div className="zs-menu-head">
          {workingCopy && <AtBadge size="sm" />}
          {id && <ChangeId id={id} length={8} />}
          {subject && <span className="zs-menu-subj">{subject}</span>}
        </div>
      )}
      {items.map((it, i) =>
        it === "sep" ? (
          <div key={"sep" + i} className="zs-menu-sep" role="separator"></div>
        ) : (
          <button key={it.id || i} type="button" role="menuitem" className={"zs-menu-item" + (it.danger ? " is-danger" : "")} disabled={it.disabled} onClick={() => onSelect && onSelect(it.id)}>
            {it.icon ? <Icon name={it.icon} size={14} /> : <span></span>}
            <span>{it.label}</span>
            {it.cmd ? <span className="zs-menu-cmd">{it.cmd}</span> : <span></span>}
          </button>
        )
      )}
    </div>
  );
}
