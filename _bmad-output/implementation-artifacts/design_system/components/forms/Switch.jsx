import React from "react";

// Switch — 30 × 18, moon when on.
export function Switch({ checked = false, onChange, label, disabled = false }) {
  return (
    <button type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled}
      className={"zs-switch" + (checked ? " is-on" : "")} onClick={() => onChange && onChange(!checked)}></button>
  );
}
