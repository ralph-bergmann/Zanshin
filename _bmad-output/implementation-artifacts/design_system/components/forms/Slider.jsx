import React from "react";

// Slider — 4px track, accent fill, --thumb knob, tabular mono readout. ticks: true (every step, when ≤ 21) or an array of values.
// The value never tweens: drag follows the pointer, a click on the track jumps there, keys land at once; the readout brightens while dragging.
// Keys: ←↓ / →↑ one step (native) · Page Down / Page Up ten steps · Home / End the ends. The fill is --accent-line.
export function Slider({ value, min = 0, max = 100, step = 1, onChange, width = 120, unit = "", label, showValue = true, ticks, disabled = false, className = "" }) {
  const [drag, setDrag] = React.useState(false);
  const p = ((value - min) / (max - min)) * 100;
  React.useEffect(() => {
    if (!drag) return;
    const up = () => setDrag(false);
    window.addEventListener("pointerup", up);
    return () => window.removeEventListener("pointerup", up);
  }, [drag]);
  let marks = [];
  if (Array.isArray(ticks)) marks = ticks;
  else if (ticks) { const n = Math.round((max - min) / step); if (n <= 20) for (let i = 0; i <= n; i++) marks.push(min + i * step); }
  return (
    <span className={["zs-slider", drag && "is-drag", disabled && "is-disabled", className].filter(Boolean).join(" ")}>
      <span className="zs-slider-track">
        <input type="range" min={min} max={max} step={step} value={value} aria-label={label} aria-valuetext={value + unit} disabled={disabled} style={{ width, "--p": p + "%" }}
          onPointerDown={() => setDrag(true)} onChange={(e) => onChange && onChange(+e.target.value)}
          onKeyDown={(e) => {
            const k = { PageUp: Math.min(max, value + step * 10), PageDown: Math.max(min, value - step * 10), Home: min, End: max }[e.key];
            if (k != null) { e.preventDefault(); if (k !== value && onChange) onChange(k); }
          }} />
        {marks.length > 0 && (
          <span className="zs-slider-ticks" aria-hidden="true">
            {marks.map((m) => <span key={m} className="zs-slider-tick" style={{ position: "absolute", left: ((m - min) / (max - min)) * 100 + "%" }}></span>)}
          </span>
        )}
      </span>
      {showValue && <span className="zs-slider-val">{value}{unit}</span>}
    </span>
  );
}
