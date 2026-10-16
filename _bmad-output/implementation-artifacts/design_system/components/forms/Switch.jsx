import React from "react";

// Switch — 30 × 18, accent when on. Press stretches the knob toward its travel; Space toggles (role switch).
export function Switch({ checked = false, onChange, label, disabled = false, className = "", ...rest }) {
  return (
    <button type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled}
      className={["zs-switch", checked && "is-on", className].filter(Boolean).join(" ")} onClick={() => onChange && onChange(!checked)} {...rest}></button>
  );
}
