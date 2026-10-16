import React from "react";

// Checkbox — one component for every check: md 15px (files, hunks, settings) · sm 13px (the Viewed chip).
// tone accent = selection (moon) · add = the Viewed review state (green). mixed = some hunks of a file; clicking mixed selects all.
// The mark is one 3-point path: unchecked → checked draws it in; checked ↔ mixed moves its points (CSS d).
// presentational: renders a span for use inside another button (the Viewed chip owns the role).
export function Checkbox({ checked = false, mixed = false, onChange, label, disabled, size = "md", tone = "accent", presentational = false, className = "", ...rest }) {
  const on = checked && !mixed;
  const cls = ["zs-check", size === "sm" && "zs-check--sm", tone === "add" && "zs-check--add", on && "is-on", mixed && "is-mixed", className].filter(Boolean).join(" ");
  const mark = (
    <svg className="zs-check-svg" viewBox="0 0 16 16" aria-hidden="true">
      <path className="zs-check-mark" pathLength="1" d={mixed ? "M4 8 L8 8 L12 8" : "M3.6 8.4 L6.6 11.3 L12.6 4.9"}></path>
    </svg>
  );
  if (presentational) return <span className={cls} aria-hidden="true">{mark}</span>;
  return (
    <button type="button" role="checkbox" aria-checked={mixed ? "mixed" : !!checked} aria-label={label} title={label} disabled={disabled} className={cls}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => { e.stopPropagation(); onChange && onChange(mixed ? true : !checked); }} {...rest}>
      {mark}
    </button>
  );
}
