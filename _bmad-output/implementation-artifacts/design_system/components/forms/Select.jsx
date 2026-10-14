import React from "react";

// Select — native dropdown in the inset-field skin (settings: remotes, trunk). options: ["origin"] or [{ value, label }]
export function Select({ options = [], value, onChange, label, className = "", ...rest }) {
  return (
    <select className={("zs-field zs-select " + className).trim()} value={value} aria-label={label} onChange={(e) => onChange && onChange(e.target.value)} {...rest}>
      {options.map((o) => {
        const v = typeof o === "string" ? o : o.value;
        return <option key={v} value={v}>{typeof o === "string" ? o : o.label}</option>;
      })}
    </select>
  );
}
