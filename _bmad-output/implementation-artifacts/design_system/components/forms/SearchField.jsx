import React from "react";
import { Icon } from "../brand/Icon.jsx";

// SearchField — 32px, quiet fill; focus = moon border + ring.
export function SearchField({ value, onChange, placeholder = "Search", autoFocus, label, style }) {
  return (
    <label className="zs-search" style={style}>
      <Icon name="search" size={14} />
      <input type="text" value={value} placeholder={placeholder} autoFocus={autoFocus} aria-label={label || placeholder}
        onChange={(e) => onChange && onChange(e.target.value)} />
    </label>
  );
}
