import React from "react";

// ProgressBar — 4px track, accent fill. value/max = determinate (width eases over --dur-panel); no value = indeterminate (a 32% sweep, --dur-shimmer).
export function ProgressBar({ value, max = 1, label, width = 200, className = "", style }) {
  const ind = value == null;
  const f = ind ? null : Math.max(0, Math.min(1, value / max));
  return (
    <span role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={max} aria-valuenow={ind ? undefined : value}
      className={["zs-progress", ind && "is-ind", className].filter(Boolean).join(" ")} style={{ width, ...style }}>
      <span className="zs-progress-fill" style={ind ? undefined : { width: f * 100 + "%" }}></span>
    </span>
  );
}
