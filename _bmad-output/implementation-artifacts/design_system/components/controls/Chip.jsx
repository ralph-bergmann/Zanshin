import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Chip — small pressable tokens. kind: toggle (on/off, e.g. "Aa" match case) · not (the "~" negation: on = red) · filter (a value with ✕) · add (dashed, "+ author")
export function Chip({ kind = "toggle", on = false, onChange, onClick, onRemove, label, mono = false, icon, size = "md", disabled, title, children, className = "", ...rest }) {
  const text = children != null ? children : label;
  const cls = ["zs-chip", "zs-chip--" + kind, size === "sm" && "zs-chip--sm", mono && "is-mono", on && "is-on", className].filter(Boolean).join(" ");
  if (kind === "filter") return (
    <span className={cls} title={title} {...rest}>
      {icon && <Icon name={icon} size="sm" />}<span className="zs-chip-l">{text}</span>
      <button type="button" className="zs-chip-x" aria-label={"Remove " + (typeof text === "string" ? text : "filter")} disabled={disabled} onClick={onRemove}><Icon name="close" size="xs" /></button>
    </span>
  );
  const toggle = kind === "toggle" || kind === "not";
  return (
    <button type="button" className={cls} title={title} disabled={disabled} aria-pressed={toggle ? on : undefined}
      onClick={(e) => { if (toggle && onChange) onChange(!on); onClick && onClick(e); }} {...rest}>
      {kind === "add" ? <Icon name="plus" size="xs" /> : icon ? <Icon name={icon} size="sm" /> : null}
      {text}
    </button>
  );
}
