import React from "react";

// GraphBreak — a shortened card-free stretch of the Free layout (sync #22, Story 10.31). A collapsed stack keeps its hidden
// members' time below it, so a long one would leave screens of canvas with only lines in it: any stretch with no card in
// any column taller than 8 pitches shrinks to 1½ pitches card to card, and this strip marks it — torn edges across the
// whole plane over the lines that run through (they read as cut), its span at the left edge with the day labels, sticky.
// top / bottom = the band between the upper card's bottom and the lower card's top; label = GraphBreak.label(t0, t1).
export function GraphBreak({ top, bottom, width, label, stickyLeft = 0, labelLeft = 14, className = "", style }) {
  const h = bottom - top, c = h / 2, up = zigzag(width, c - 9, 0), lo = zigzag(width, c + 9, 1);
  return (
    <div className={("zs-break " + className).trim()} style={{ top, width, height: h, ...style }} aria-hidden="true">
      <svg className="zs-break-strip" width={width} height={h}>
        <path className="zs-break-fill" d={"M" + up.join(" L") + " L" + [...lo].reverse().join(" L") + " Z"}></path>
        <polyline className="zs-break-edge" points={up.join(" ")}></polyline>
        <polyline className="zs-break-edge" points={lo.join(" ")}></polyline>
      </svg>
      {label && <span className="zs-break-label" style={{ left: stickyLeft + labelLeft, marginLeft: labelLeft }}>{label}</span>}
    </div>
  );
}

// the torn edge: a zigzag of amplitude 3 every 9px
function zigzag(width, y, phase, amp = 3, step = 9) {
  const pts = [];
  for (let x = 0, k = phase; x <= width + step; x += step, k++) pts.push(Math.min(x, width) + "," + (y + (k % 2 ? -amp : amp)));
  return pts;
}

// The span a break skips, from the lower card's time t0 to the upper card's t1 (ms):
// "4 years · Feb 2021 – Mar 2025" · "8 months · Jun – Dec 2025" · "3 weeks · Jun 3 – 24"
GraphBreak.label = function (t0, t1) {
  const d = (t1 - t0) / 864e5, a = new Date(t0), b = new Date(t1), M = (x) => x.toLocaleDateString("en-US", { month: "short" });
  const len = d >= 548 ? Math.round(d / 365) + " years" : d >= 60 ? Math.round(d / 30.4) + " months" : d >= 14 ? Math.round(d / 7) + " weeks" : Math.max(1, Math.round(d)) + " days";
  const range = a.getFullYear() !== b.getFullYear() ? `${M(a)} ${a.getFullYear()} – ${M(b)} ${b.getFullYear()}`
    : a.getMonth() !== b.getMonth() ? `${M(a)} – ${M(b)} ${b.getFullYear()}` : `${M(a)} ${a.getDate()} – ${b.getDate()}`;
  return len + " · " + range;
};
