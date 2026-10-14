import React from "react";

// Slider — 4px track, moon fill, white 14px thumb, mono value readout.
export function Slider({ value, min = 0, max = 100, step = 1, onChange, width = 120, unit = "", label, showValue = true }) {
  const p = ((value - min) / (max - min)) * 100;
  return (
    <span className="zs-slider">
      <input type="range" min={min} max={max} step={step} value={value} aria-label={label} style={{ width, "--p": p + "%" }}
        onChange={(e) => onChange && onChange(+e.target.value)} />
      {showValue && <span className="zs-slider-val">{value}{unit}</span>}
    </span>
  );
}
