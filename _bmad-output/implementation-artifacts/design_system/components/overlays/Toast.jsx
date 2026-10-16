import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Toast — every graph edit can be taken back. Glass pill at the bottom centre: what happened (ids in mono), Undo (jj undo), dismiss.
// tone: success (default — past tense + Undo, 6.5s) · warn (refused, nothing changed — 6.5s) · error (failed — action Retry, stays until dismissed).
// One at a time: a new toast replaces the current one (replaced → the old fades in place, the new rises in). closing → slides down and fades.
export function Toast({ children, tone = "success", onUndo, undoLabel = "Undo", action, onClose, closing = false, replaced = false, className = "", style }) {
  const icon = tone === "warn" ? "conflict" : tone === "error" ? "alert" : null;
  const cls = ["zs-toast", tone !== "success" && "is-" + tone, closing && "is-closing", replaced && "is-replaced", className].filter(Boolean).join(" ");
  return (
    <div role={tone === "error" ? "alert" : "status"} className={cls} style={style}>
      {icon && <span className="zs-toast-ic"><Icon name={icon} size="md" /></span>}
      <span className="zs-toast-t">{children}</span>
      {onUndo && <button type="button" className="zs-toast-undo" onClick={onUndo} title="jj undo">{undoLabel}</button>}
      {action && <button type="button" className="zs-toast-undo" onClick={action.onClick} title={action.title}>{action.label}</button>}
      {onClose && <button type="button" className="zs-toast-x" onClick={onClose} aria-label="Dismiss"><Icon name="close" size="xs" /></button>}
    </div>
  );
}
