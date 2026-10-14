import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Checkbox — selection of files and hunks (inspector). Moon like every other selection; mixed = some hunks of a file.
// Clicking mixed selects everything, like the client's file toggle.
export function Checkbox({ checked = false, mixed = false, onChange, label, disabled, className = "", ...rest }) {
  const on = checked && !mixed;
  return (
    <button type="button" role="checkbox" aria-checked={mixed ? "mixed" : !!checked} aria-label={label} title={label} disabled={disabled}
      className={["zs-check", on && "is-on", mixed && "is-mixed", className].filter(Boolean).join(" ")}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => { e.stopPropagation(); onChange && onChange(mixed ? true : !checked); }} {...rest}>
      {on && <Icon name="check-bold" size={10} />}
      {mixed && <Icon name="dash-bold" size={10} />}
    </button>
  );
}
