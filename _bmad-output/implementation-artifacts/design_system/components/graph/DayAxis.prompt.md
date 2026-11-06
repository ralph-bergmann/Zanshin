The day axis of the **Free** layout (the default) — calendar days on the graph without a gutter. Compact has no day axis.

~~~jsx
<div className="plane" style={{ position: "relative", width: 700, height: 420 }}>
  <DayAxis width={700} height={420} stickyLeft={inset - 6} labelLeft={2} days={[
    { key: "today", label: "Today", y: 150, guide: 150 },
    { key: "yday", label: "Yesterday", y: 288, guide: 288 },
    { key: "sep23", label: "Sep 23", y: 392 },          // the oldest day: below its first commit, no divider
  ]}/>
  {/* lines (svg) and cards come after it */}
</div>
~~~

- **Where a label sits:** on the dashed divider below that day's first commit, at the left edge — reading upward, a label means "this day starts here". The divider runs midway between the top of the previous day's newest card and the bottom of this day's oldest card; labels keep ≥ 22px apart. The oldest day's label sits below its first commit (midway to the root, or half a gap below).
- **No gutter:** Free reserves no extra width. Days never interleave in Free (rows follow commit time), so the band around a divider never holds cards.
- **Sticky:** the label column stays at the left edge while the graph scrolls sideways — in the floating client right of the rail or the pinned panel (`stickyLeft = inset − 6`, `labelLeft = 2`).
- **Look:** `DayLabel` is mono 11px in `--text-muted` on a `--card-solid` pill with a 1px `--border`, radius 5; the divider is 1px `--border-strong`, dashed 2 6.
- **Years** (sync #22): a day label never carries a year ("Dec 16", not "Dec 16, 2015"). Where a year begins, `years` puts the year as its own label just above that day's label (600, `--fs-xs`, `--tracking-pill`, `--text-muted`) — reading upward, "2025 starts here", like the day labels. None for a history inside one year, none at a boundary inside a `GraphBreak` (its label names both ends). A divider inside a break is dropped from `days`.
- **Minimap:** uses the same day labels; its current-day pill names the day the viewport centre is in (labels mark a day's bottom edge). It reads its years top-down instead: each boundary heads the section below it (the older year), and the year at its top sticks as a header (readme › Time in the graph).
- Cards keep their relative age (`now`, `3h`, `2d`); the axis only ever shows calendar days.
