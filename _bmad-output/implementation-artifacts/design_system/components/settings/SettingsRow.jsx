import React from "react";
import { Icon } from "../brand/Icon.jsx";

// SettingsRow — label (+ hint, + the jj config key it writes) left, control right. stack: the control goes full-width below (long revsets).
// onOpen: a navigation row — the whole row is a button that opens a page inside the tab (SettingsPage); the right side shows a value
// (children, e.g. a count) and ›. Hover --fl-on, pressed --fl-press, the box's corners where it is first or last.
export function SettingsRow({ label, hint, configKey, stack = false, onOpen, children, className = "" }) {
  const cls = ["zs-setrow", stack && "is-stack", onOpen && "is-nav", className].filter(Boolean).join(" ");
  const body = (
    <>
      <div className="zs-setrow-lbl">
        <span>{label}</span>
        {hint && <span className="zs-setrow-hint">{hint}</span>}
        {configKey && <code className="zs-setrow-cfg">{configKey}</code>}
      </div>
      <div className="zs-setrow-ctl">{children}{onOpen && <Icon className="zs-setrow-chev" name="chevron-right" size="sm" />}</div>
    </>
  );
  return onOpen ? <button type="button" className={cls} onClick={onOpen}>{body}</button> : <div className={cls}>{body}</div>;
}
