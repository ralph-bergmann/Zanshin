import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { IconButton } from "../actions/IconButton.jsx";

// Dialog — modal sheet on a blurred scrim. Optional left nav (Projects: brand on top, nav items, signed-in user at the foot),
// a toolbar row, and a scrolling body. The scrim fills its positioned parent (absolute) — place the Dialog inside the window frame.
export function Dialog({ title, onClose, nav, activeNav, onNav, navHeader, navFooter, tools, width = 900, height = 640, scrim = true, className = "", children }) {
  const box = (
    <div role="dialog" aria-modal="true" aria-label={title} className={["zs-dialog", (nav || navHeader) && "has-nav", className].filter(Boolean).join(" ")}
      style={{ width, height }} onClick={(e) => e.stopPropagation()} onMouseDown={(e) => e.stopPropagation()}>
      {(nav || navHeader) && (
        <nav className="zs-dialog-nav">
          {navHeader}
          {nav && (
            <div className="zs-dialog-navlist">
              {nav.map((n) => (
                <button key={n.id} type="button" className={"zs-dialog-navitem" + (n.id === activeNav ? " is-on" : "")} onClick={() => onNav && onNav(n.id)}>
                  {n.icon && <Icon name={n.icon} size={14} />}
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
          {onClose && <IconButton icon="close" iconSize={12} label="Close (Esc)" size="sm" onClick={onClose} />}
        </div>
        {tools && <div className="zs-dialog-tools">{tools}</div>}
        <div className="zs-dialog-bd">{children}</div>
      </div>
    </div>
  );
  return scrim ? <div className="zs-scrim" onMouseDown={onClose}>{box}</div> : box;
}
