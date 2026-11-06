A shortened stretch of the **Free** layout — how a long history stays readable (Story 10.31, sync #22).

~~~jsx
<div className="plane" style={{ position: "relative", width: 900, height: 600 }}>
  <DayAxis width={900} height={600} days={days} years={years}/>
  {/* lines (svg) */}
  <GraphBreak top={190} bottom={293} width={900} label={GraphBreak.label(Date.parse("2019-09-18"), Date.parse("2025-05-10"))}/>
  {/* cards */}
</div>
~~~

- **Why:** a collapsed stack keeps its hidden members' time below it (collapsing never moves anything else), so a long stack would leave screens of canvas with only its line in it — on a real 12-year repo, 64 screens under one 486-change stack. Gaps between commits never get that tall: Free damps them (log, at most 3 pitches).
- **The rule (layout):** any vertical stretch with **no card in any column** taller than **8 pitches** shrinks to **1½ pitches** card to card. In layout units, so a break never depends on the window. Every view reads the shortened mapping: canvas, day axis, gap markers, go-to and scroll math, the minimap.
- **Expanding** the stack fills the stretch with its cards — the break is gone; collapsing brings it back. No "show gap" of its own.
- **Look:** a strip across the whole plane, two torn edges (zigzag, amplitude 3, every 9px) in `--border-strong`, filled with `--fl-bg-solid` at .92 — over the lines, which read as cut at its edges; under the cards. The label (mono 11, `--text-dim` on a `--card-solid` pill) sits at the left edge with the day labels, sticky.
- **Label:** `GraphBreak.label(t0, t1)` — the length, then the range: "4 years · Feb 2021 – Mar 2025", "8 months · Jun – Dec 2025", "3 weeks · Jun 3 – 24" (t0 = the lower card's time, t1 = the upper card's).
- **Day axis:** a day divider inside a break is dropped (the break names both ends); a year boundary inside it gets no year label on the canvas — the minimap still heads its section.
- **Minimap:** a small zigzag across the graph part at the break's centre.
