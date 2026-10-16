import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Kbd } from "../content/Kbd.jsx";

// SearchField — 30px (--control-md), a quiet FILL at rest (a named exception to the text-entry well, as NSSearchField); focus = accent edge + halo. A clear ✕ appears with a query; Esc clears, a second Esc leaves the field.
// shortcut: a key cap shown while the field is empty and unfocused (the one place a key cap sits outside prose).
export function SearchField({ value = "", onChange, placeholder = "Search", autoFocus, label, style, shortcut, onClear, className = "" }) {
  const ref = React.useRef(null);
  const [focus, setFocus] = React.useState(false);
  const clear = () => { onChange && onChange(""); onClear && onClear(); ref.current && ref.current.focus(); };
  return (
    <label className={("zs-search " + className).trim()} style={style}>
      <Icon name="search" size="md" />
      <input ref={ref} type="text" value={value} placeholder={placeholder} autoFocus={autoFocus} aria-label={label || placeholder}
        onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
        onKeyDown={(e) => { if (e.key === "Escape") { if (value) { e.preventDefault(); clear(); } else e.currentTarget.blur(); } }}
        onChange={(e) => onChange && onChange(e.target.value)} />
      {value ? <button type="button" className="zs-search-x" aria-label="Clear search" title="Clear (Esc)" onClick={clear}><Icon name="close" size="xs" /></button>
        : shortcut && !focus ? <Kbd>{shortcut}</Kbd> : null}
    </label>
  );
}
