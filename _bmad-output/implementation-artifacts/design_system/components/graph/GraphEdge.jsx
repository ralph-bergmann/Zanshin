import React from "react";

// Graph line geometry — the floating client's router (graph-layout.jsx). One line per parent → child pair: every line has its own
// exit on the parent's top edge and its own entry on the child's bottom edge; forks turn just above the parent, merges just below the
// child; horizontal runs stack in tracks 3.5–6px apart and nest instead of crossing.
// Ports, top and bottom alike: one line → the centre; several → the straight one takes the centre and the rest fan to their side;
// none straight → the centre stays free. A merge-up exit never takes the centre and sits MERGE_UP_SHIFT outside its slot.
const ZS_ENTRY = { first: 24, step: 16, min: 8, inset: 18 }; // the fan on either edge, offsets from the centre
const ZS_MERGE_UP_SHIFT = 4;
const ZS_CUT_CLEAR = 12;                                      // a break keeps this much visible line to the next bend or card

// m ports, inner → outer: `step` apart while they fit, squeezed down to `min`; past that the overflow shares the outermost port
function zsFan(m, first, step, min, max) {
  if (m <= 1) return m ? [first] : [];
  const span = Math.max(0, max - first), st = Math.min(step, span / (m - 1));
  if (st >= min) return [...Array(m).keys()].map((k) => first + k * st);
  const own = Math.floor(span / min);
  return [...Array(m).keys()].map((k) => first + Math.min(k, own) * min);
}

export const GraphPorts = {
  ENTRY: ZS_ENTRY, MERGE_UP_SHIFT: ZS_MERGE_UP_SHIFT, CUT_CLEAR: ZS_CUT_CLEAR, TRACK: { min: 3.5, max: 6 }, BAND_INSET: 12, RADIUS: 10,
  // m lines leaving one side of a parent's top edge, when more than one line leaves it → offsets from the card centre, innermost
  // first: the entries' fan (a lone line or the straight one uses the centre; add MERGE_UP_SHIFT for a merge-up).
  exits(m, cardW) { return zsFan(m, ZS_ENTRY.first, ZS_ENTRY.step, ZS_ENTRY.min, cardW / 2 - ZS_ENTRY.inset); },
  // the lines entering one side of a child's bottom edge beside the centre one (a lone line or the straight one), nearest parent
  // first (24px out, 16px apart, down to 8)
  entries(m, cardW) { return zsFan(m, ZS_ENTRY.first, ZS_ENTRY.step, ZS_ENTRY.min, cardW / 2 - ZS_ENTRY.inset); },
  // spacing of n stacked runs in one band — the band between two cards keeps 12px off each, leaving 24px of room
  trackSpacing(n, room = 24) { return n > 1 ? Math.max(3.5, Math.min(6, room / (n - 1))) : 0; },
  // the break a crossing leaves: 12 × 10 in the horizontal line, or 10 × 12 in the vertical one when the horizontal has no room
  bridge(x, y, broken = "h") { return broken === "h" ? { x: x - 6, y: y - 5, w: 12, h: 10 } : { x: x - 5, y: y - 6, w: 10, h: 12 }; },
};

// Orthogonal polyline with rounded elbows (same construction as the client's edge router).
function zsRoundedPath(raw, r) {
  const pts = raw.filter((p, i) => i === 0 || p[0] !== raw[i - 1][0] || p[1] !== raw[i - 1][1]);
  let d = "M" + pts[0][0] + "," + pts[0][1];
  for (let i = 1; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i - 1], [x1, y1] = pts[i], [x2, y2] = pts[i + 1];
    const l1 = Math.hypot(x1 - x0, y1 - y0), l2 = Math.hypot(x2 - x1, y2 - y1);
    const rr = Math.min(r, l1 / 2, l2 / 2);
    d += " L" + (x1 - ((x1 - x0) / l1) * rr) + "," + (y1 - ((y1 - y0) / l1) * rr) + " Q" + x1 + "," + y1 + " " + (x1 + ((x2 - x1) / l2) * rr) + "," + (y1 + ((y2 - y1) / l2) * rr);
  }
  const last = pts[pts.length - 1];
  return d + " L" + last[0] + "," + last[1];
}

// Where the gap marker goes (graph-gaps.jsx): the first stretch with room, scanning from the child — vertical runs first. The break
// never sits right at a card: 8px from the card edge or 12px from a bend, centred in what is left; with no room, the middle of the longest run.
function zsGapSpot(pts) {
  const S = [];
  for (let i = 1; i < pts.length; i++) {
    const [x1, y1] = pts[i - 1], [x2, y2] = pts[i];
    if (x1 === x2 && y1 === y2) continue;
    S.push({ x1, y1, x2, y2, h: y1 === y2, len: Math.abs(x2 - x1) + Math.abs(y2 - y1) });
  }
  const at = (s, u) => ({ x: s.x2 + ((s.x1 - s.x2) / s.len) * u, y: s.y2 + ((s.y1 - s.y2) / s.len) * u, dir: s.h ? "h" : "v" });
  for (const wantH of [false, true]) for (let k = S.length - 1; k >= 0; k--) {
    const s = S[k]; if (s.h !== wantH) continue;
    const need = s.h ? 30 : 26, lo = k === S.length - 1 ? 8 : 12, hi = s.len - (k === 0 ? 8 : 12);
    if (hi - lo >= need) return at(s, lo + Math.min((hi - lo) / 2, need / 2 + 6));
  }
  const best = S.reduce((b, s) => (!b || s.len > b.len ? s : b), null);
  return best ? at(best, best.len / 2) : null;
}

// The "break" mark: two short slanted cuts across the line (the client's settled gap marker).
function zsCuts(m) {
  return [-3, 3].map((d) => m.dir === "h"
    ? <line key={d} className="zs-gap-cut" x1={m.x + d - 2.2} y1={m.y + 5} x2={m.x + d + 2.2} y2={m.y - 5}></line>
    : <line key={d} className="zs-gap-cut" x1={m.x - 5} y1={m.y + d + 2.2} x2={m.x + 5} y2={m.y + d - 2.2}></line>);
}

// GraphEdge — one parent → child line. Render inside an <svg>. Parents sit below, children above (jj log order).
// from = the line's exit on the parent's top edge (GraphPorts.exits; a straight line leaves from the centre),
// to = its entry on the child's bottom edge (first parent: bottom centre; other parents beside it, GraphPorts.entries).
// Lane changes turn once at `bend` — the track the router gave this run. kind: normal · wc (the path from @ down to trunk) · hover · dim.
// gap = the revset hides changes in between: dashed, with the break mark where the line has room (or at `gapAt`).
// cuts = bridges: where another line crosses, this one breaks (GraphPorts.bridge) and keeps ≥ 12px of line to the next bend or card.
export function GraphEdge({ from, to, points, bend, kind = "normal", radius = 10, gap = false, gapAt, cuts }) {
  const uid = React.useId().replace(/[^a-zA-Z0-9]/g, "");
  let pts = points;
  if (!pts) {
    const [x1, y1] = from, [x2, y2] = to;
    const ym = bend != null ? bend : (y1 + y2) / 2;
    pts = x1 === x2 ? [from, to] : [from, [x1, ym], [x2, ym], to];
  }
  const mod = kind !== "normal" ? " is-" + kind : "";
  const cls = "zs-edge" + mod + (gap ? " is-gap" : "");
  const spot = gap && gapAt !== false ? (gapAt || zsGapSpot(pts)) : null;
  const holes = [...(cuts || []), ...(spot ? [spot.dir === "h" ? { x: spot.x - 4, y: spot.y - 6, w: 8, h: 12 } : { x: spot.x - 6, y: spot.y - 4, w: 12, h: 8 }] : [])];
  const d = zsRoundedPath(pts, radius);
  if (!holes.length) return gap ? <g className={"zs-gap" + mod}><path className={cls} d={d}></path></g> : <path className={cls} d={d}></path>;
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const bx = Math.min(...xs) - 24, by = Math.min(...ys) - 24, bw = Math.max(...xs) - bx + 24, bh = Math.max(...ys) - by + 24;
  const id = "zs-edge-m" + uid;
  return (
    <g className={gap ? "zs-gap" + mod : undefined}>
      <defs>
        <mask id={id} maskUnits="userSpaceOnUse" x={bx} y={by} width={bw} height={bh}>
          <rect x={bx} y={by} width={bw} height={bh} fill="white"></rect>
          {holes.map((r, i) => <rect key={i} x={r.x} y={r.y} width={r.w} height={r.h} fill="black"></rect>)}
        </mask>
      </defs>
      <path className={cls} d={d} mask={"url(#" + id + ")"}></path>
      {spot && zsCuts(spot)}
    </g>
  );
}

// GraphEnd — older history isn't in the revset: a short dashed stub under the card, two cuts and "~ elided".
// x, y = where the stub leaves the card's bottom edge (centred, or beside the card's entries so it never sits on a real line).
export function GraphEnd({ x, y, label = "~ elided", kind = "normal" }) {
  return (
    <g className={"zs-gap" + (kind !== "normal" ? " is-" + kind : "")}>
      <path className={"zs-edge is-gap" + (kind !== "normal" ? " is-" + kind : "")} d={"M" + x + "," + y + " L" + x + "," + (y + 8)}></path>
      {[y + 10.5, y + 15].map((cy) => <line key={cy} className="zs-gap-cut" x1={x - 5} y1={cy + 2.2} x2={x + 5} y2={cy - 2.2}></line>)}
      {label && <text className="zs-gap-txt" x={x + 11} y={y + 16}>{label}</text>}
    </g>
  );
}
