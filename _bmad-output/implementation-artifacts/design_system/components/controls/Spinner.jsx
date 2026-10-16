import React from "react";

// Spinner — the inline busy mark, 12–16px: a quarter arc on a faint ring, one turn per --dur-spin (800ms), linear. currentColor.
// Keeps turning under reduce motion — it is information, not decoration.
export function Spinner({ size = 14, label, className = "", style }) {
  return (
    <svg className={("zs-spinner " + className).trim()} width={size} height={size} viewBox="0 0 16 16" style={style}
      role={label ? "progressbar" : undefined} aria-label={label} aria-hidden={label ? undefined : true}>
      <circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" strokeOpacity=".22" strokeWidth="2"></circle>
      <path d="M8 2a6 6 0 0 1 6 6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"></path>
    </svg>
  );
}
