import React from "react";

// DayLabel — one calendar day on the graph's day axis: "Today", "Yesterday", "Sep 23" — never a year (sync #22).
export function DayLabel({ children, className = "", style }) {
  return <div className={("zs-day-label " + className).trim()} style={style}>{children}</div>;
}

// DayAxis — the Free layout's day axis. No gutter: a dashed divider runs between two calendar days, and each day's label sits on
// the divider below that day's first commit, at the left edge, sticky. The oldest day's label sits below its first commit.
// Reading upward: label = "this day starts here". Days never interleave in Free, so the band around a divider holds no cards.
// days: [{ key, label, y, guide }] — y = label centre; guide = divider y (none for the oldest day).
// years: [{ key, year, y }] — where a year begins (sync #22): the year above the divider, its own label just above that day's
// label (y = the day label's y). None where the history holds one year, none inside a GraphBreak.
// Place it first in the graph plane (under cards and lines); the labels stay in view while the plane scrolls sideways.
export function DayAxis({ days = [], years = [], width, height, x0 = 0, stickyLeft = 0, labelLeft = 14, className = "", style }) {
  return (
    <div className={("zs-days " + className).trim()} style={{ width, height, ...style }} aria-hidden="true">
      <svg className="zs-days-guides" width={width} height={height}>
        {days.filter((d) => d.guide != null).map((d) => <line key={d.key || d.label} className="zs-day-guide" x1={x0} x2={width} y1={d.guide} y2={d.guide}></line>)}
      </svg>
      <div className="zs-days-col" style={{ left: stickyLeft, height }}>
        {days.map((d) => <DayLabel key={d.key || d.label} style={{ top: d.y, left: labelLeft }}>{d.label}</DayLabel>)}
        {years.map((y) => <span key={y.key || y.year} className="zs-year-label" style={{ top: y.y, left: labelLeft }}>{y.year}</span>)}
      </div>
    </div>
  );
}
