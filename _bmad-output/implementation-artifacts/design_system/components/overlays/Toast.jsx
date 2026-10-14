import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Toast — every graph edit can be taken back. Glass pill at the bottom centre: what happened (ids in mono), Undo (jj undo), dismiss.
// The client keeps it 6.5s; while it shows, the @ locator steps aside.
export function Toast({ children, onUndo, onClose, undoLabel = "Undo", className = "", style }) {
  return (
    <div role="status" className={("zs-toast " + className).trim()} style={style}>
      <span className="zs-toast-t">{children}</span>
      {onUndo && <button type="button" className="zs-toast-undo" onClick={onUndo} title="jj undo">{undoLabel}</button>}
      {onClose && <button type="button" className="zs-toast-x" onClick={onClose} aria-label="Dismiss"><Icon name="close" size={10} /></button>}
    </div>
  );
}
