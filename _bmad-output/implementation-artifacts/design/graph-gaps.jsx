/* global React */
// Hidden history: gap markers on indirect edges, end stubs for missing parents, hover callouts, toolbar legend.
(() => {
const { useState } = React;

// Marker spot: first free stretch on the edge, scanning from the child (the gap starts right below it).
// Free = away from corners, card borders, crossings and stretches shared with other edges.
function placeGapMarkers(edges) {
  const segs = edges.map(e => {
    const s = [];
    for (let i = 1; i < e.pts.length; i++) {
      const [x1, y1] = e.pts[i - 1], [x2, y2] = e.pts[i];
      if (x1 === x2 && y1 === y2) continue;
      s.push({ x1, y1, x2, y2, h: y1 === y2, len: Math.abs(x2 - x1) + Math.abs(y2 - y1) });
    }
    return s;
  });
  const spot = (i) => {
    const S = segs[i];
    for (const wantH of [false, true]) for (let si = S.length - 1; si >= 0; si--) {
      const s = S[si]; if (s.h !== wantH) continue;
      const need = s.h ? 30 : 26, m0 = si === S.length - 1 ? 8 : 12, m1 = si === 0 ? 8 : 12;
      const ux = (s.x1 - s.x2) / s.len, uy = (s.y1 - s.y2) / s.len;
      const U = (x, y) => (x - s.x2) * ux + (y - s.y2) * uy;
      const bad = [];
      segs.forEach((T, j) => { if (j !== i) T.forEach(t => {
        if (t.h !== s.h) {
          const hs = s.h ? s : t, vs = s.h ? t : s, X = vs.x1, Y = hs.y1;
          if (X >= Math.min(hs.x1, hs.x2) - 1 && X <= Math.max(hs.x1, hs.x2) + 1 && Y >= Math.min(vs.y1, vs.y2) - 1 && Y <= Math.max(vs.y1, vs.y2) + 1) {
            const u = U(X, Y); bad.push([u - 11, u + 11]);
          }
        } else if (Math.abs((s.h ? s.y1 - t.y1 : s.x1 - t.x1)) <= 3) {
          const a = U(t.x1, t.y1), b = U(t.x2, t.y2);
          bad.push([Math.min(a, b) - 5, Math.max(a, b) + 5]);
        }
      }); });
      bad.sort((a, b) => a[0] - b[0]);
      let a = m0;
      const tryIv = (lo, hi) => hi - lo >= need ? lo + Math.min((hi - lo) / 2, need / 2 + 6) : null;
      let u = null;
      for (const [b0, b1] of bad) { if (b0 > a) { u = tryIv(a, Math.min(b0, s.len - m1)); if (u != null) break; } a = Math.max(a, b1); }
      if (u == null) u = tryIv(a, s.len - m1);
      if (u != null) return { x: s.x2 + ux * u, y: s.y2 + uy * u, dir: s.h ? "h" : "v" };
    }
    const end = edges[i].pts[edges[i].pts.length - 1];
    return { x: end[0], y: end[1] + 11, dir: "v" };
  };
  const groups = new Map();
  edges.forEach((e, i) => { if (!e.dashed) return; const k = e.to + "|" + e.via; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(i); });
  const out = [];
  groups.forEach((idx, key) => {
    const e0 = edges[idx[0]], end = e0.pts[e0.pts.length - 1];
    // several indirect edges through the same hidden parent (= hidden merge) share one marker on the card's stem
    if (idx.length > 1 && !edges.some((e, j) => e.to === e0.to && !idx.includes(j))) {
      const ids = [...new Set(idx.flatMap(i => edges[i].hiddenIds))];
      out.push({ key, edges: idx, from: idx.map(i => edges[i].from), to: e0.to, via: e0.via, count: ids.length, hiddenIds: ids, group: true, x: end[0], y: end[1] + 10, dir: "v" });
      return;
    }
    idx.forEach(i => out.push({ key: key + "|" + edges[i].from, edges: [i], from: [edges[i].from], to: e0.to, via: e0.via, count: edges[i].count, hiddenIds: edges[i].hiddenIds, ...spot(i) }));
  });
  return out;
}

// cut in the edge underneath a marker (plane coords)
function gapCut(m, variant) {
  if (variant === "pill") return null;
  const along = variant === "dots" ? (m.group ? 16 : 24) : 8, across = 12;
  return m.dir === "v" ? { x: m.x - across / 2, y: m.y - along / 2, w: across, h: along } : { x: m.x - along / 2, y: m.y - across / 2, w: along, h: across };
}

const pillW = (txt) => 14 + txt.length * 6.3;

function GapMark({ m, variant, count, cls = "" }) {
  const { x, y, dir } = m, v = dir === "v";
  const lbl = count != null && variant !== "pill" && (
    <text className="ggap-txt" x={v ? x + 10 : x} y={v ? y + 4 : y - 10} textAnchor={v ? "start" : "middle"}>{count} elided</text>
  );
  let body;
  if (variant === "dots") body = [-5.5, 0, 5.5].map(d => <circle key={d} className="ggap-ink" cx={v ? x : x + d} cy={v ? y + d : y} r="1.7"/>);
  else if (variant === "break") body = [-3, 3].map(d => v
    ? <line key={d} className="ggap-cut" x1={x - 5} y1={y + d + 2.2} x2={x + 5} y2={y + d - 2.2}/>
    : <line key={d} className="ggap-cut" x1={x + d - 2.2} y1={y + 5} x2={x + d + 2.2} y2={y - 5}/>);
  else {
    const txt = count != null ? String(count) : null, w = txt ? Math.max(20, pillW(txt)) : 22;
    body = <>
      <rect className="ggap-pill" x={x - w / 2} y={y - 7} width={w} height="14" rx="7"/>
      {txt ? <text className="ggap-pill-txt" x={x} y={y + 3.6}>{txt}</text>
        : [-4, 0, 4].map(d => <circle key={d} className="ggap-ink" cx={x + d} cy={y} r="1.25"/>)}
    </>;
  }
  return <g className={"ggap " + cls}>{body}{lbl}</g>;
}

// End of history along a parent ("missing"). Stub hangs from (x,y) = card bottom.
function GapEnd({ s, variant, count, cls = "", noLabel }) {
  const { x, y } = s;
  const label = count != null ? `~ ${count} elided` : "~ elided";
  if (variant === "pill") {
    const txt = count != null ? `~ ${count}` : "~", w = Math.max(22, pillW(txt));
    return <g className={"ggap " + cls}>
      <path className="gedge dashed gend-line" d={`M${x},${y} L${x},${y + 4}`}/>
      <rect className="ggap-pill" x={x - w / 2} y={y + 4} width={w} height="14" rx="7"/>
      <text className="ggap-pill-txt" x={x} y={y + 14.6}>{txt}</text>
    </g>;
  }
  if (variant === "break") return <g className={"ggap " + cls}>
    <path className="gedge dashed gend-line" d={`M${x},${y} L${x},${y + 8}`}/>
    {[10.5, 15].map(d => <line key={d} className="ggap-cut" x1={x - 5} y1={y + d + 2.2} x2={x + 5} y2={y + d - 2.2}/>)}
    {!noLabel && <text className="ggap-txt" x={x + 11} y={y + 16}>{label}</text>}
  </g>;
  return <g className={"ggap " + cls}>
    <path className="gedge dashed gend-line" d={`M${x},${y} L${x},${y + 7}`}/>
    {[[10.5, .9], [14.5, .55], [18.5, .25]].map(([d, o]) => <circle key={d} className="ggap-ink" cx={x} cy={y + d} r="1.6" style={{ opacity: o }}/>)}
    {!noLabel && <text className="ggap-txt" x={x + 10} y={y + 15}>{label}</text>}
  </g>;
}

// Legend glyphs (28×28)
function GlyphDirect() { return <svg width="22" height="22" viewBox="0 0 28 28"><path className="gedge" d="M14,1 L14,27"/></svg>; }
function GlyphGap({ variant }) {
  const m = { x: 14, y: 14, dir: "v" }, cut = variant === "pill" ? 0 : variant === "dots" ? 11 : 4;
  return <svg width="22" height="22" viewBox="0 0 28 28">
    <path className="gedge dashed" d={`M14,1 L14,${14 - cut}`}/><path className="gedge dashed" d={`M14,${14 + cut} L14,27`}/>
    <GapMark m={m} variant={variant}/>
  </svg>;
}
function GlyphEnd({ variant }) {
  return <svg width="22" height="22" viewBox="0 0 28 28"><GapEnd s={{ x: 14, y: 4 }} variant={variant} noLabel/></svg>;
}

function nodeLabel(c) {
  const d = c.isGroup ? c.members[c.members.length - 1] : c;
  return { id: d.id, subject: d.subject, stack: c.isGroup ? c.members.length : 0 };
}
function GapRow({ c }) {
  const l = nodeLabel(c);
  return (
    <div className="ggap-row">
      <span className="gcid"><b>{l.id.slice(0, 2)}</b>{l.id.slice(2, 6)}</span>
      <span className="ggap-row-subj">{l.subject}</span>
      {l.stack > 0 && <span className="gstack-n">{l.stack}</span>}
    </div>
  );
}

function GapPeek({ g, N, variant, showCount, counted, onCount, onReveal, onEnter, onLeave, flip }) {
  const isEnd = g.kind === "end", child = N.get(isEnd ? g.node : g.to).c;
  const known = showCount || counted;
  const n = g.count;
  const countEl = known
    ? <span>{isEnd ? `${n} older commit${n === 1 ? "" : "s"} not shown` : `${n} commit${n === 1 ? "" : "s"} hidden`}</span>
    : <span>{isEnd ? "Older history not shown" : "Hidden commits"}<span className="ggap-sep">·</span><button className="ggap-link" onClick={onCount}>Count</button></span>;
  return (
    <div className={"ggap-pop " + (flip ? "flip" : "")} style={{ left: flip ? g.x - 18 : g.x + 18, top: g.y - 22 }}
      onMouseEnter={onEnter} onMouseLeave={onLeave} onPointerDown={e => e.stopPropagation()}>
      <div className="gpeek-inner">
        <div className="gpeek-subj">{isEnd ? "History continues outside this revset" : g.group ? "A hidden merge sits below this change" : "Commits hidden between these changes"}</div>
        <div className="ggap-chain">
          <GapRow c={child}/>
          <div className="ggap-mid">
            <svg width="16" height="22" viewBox="6 3 16 22">{isEnd ? <GapEnd s={{ x: 14, y: 4 }} variant={variant} noLabel/> : <GapMark m={{ x: 14, y: 14, dir: "v" }} variant={variant}/>}</svg>
            {countEl}
          </div>
          {isEnd
            ? <div className="ggap-row is-hidden"><span className="gcid"><b>{g.via.slice(0, 2)}</b>{g.via.slice(2, 6)}</span><span className="ggap-row-subj">parent, not in revset</span></div>
            : g.from.map(id => <GapRow key={id} c={N.get(id).c}/>)}
        </div>
        <div className="gpeek-desc">
          {isEnd ? "No ancestor reached through this parent is part of the current revset."
            : g.group ? "The only parent is hidden and is itself a merge, so the gap leads to two visible ancestors."
            : "The dashed edge skips commits the revset doesn't include and links to the nearest visible ancestor."}
        </div>
        <div className="ggap-actions">
          <button className="ggap-btn" onClick={onReveal}>Show in <code>all()</code></button>
          <span className="gpeek-dim">switches revset · centers here</span>
        </div>
      </div>
    </div>
  );
}

function GapLegend({ variant, gaps, ends, onShowAll }) {
  const n = gaps + ends;
  if (!n) return null;
  return (
    <div className="gtb-gaps">
      <button className="gtb-gaps-btn" aria-label="What dashed edges mean">
        <svg width="12" height="18" viewBox="7 2 14 24"><path className="gedge dashed" d="M14,2 L14,8"/><path className="gedge dashed" d="M14,20 L14,26"/><GapMark m={{ x: 14, y: 14, dir: "v" }} variant={variant}/></svg>
        <span>{n} {n === 1 ? "gap" : "gaps"}</span>
      </button>
      <div className="gtb-gaps-pop">
        <div className="gtb-gaps-inner">
          <div className="gpeek-subj">This revset hides part of the history</div>
          <div className="gtb-gaps-row"><GlyphDirect/><span><b>Solid</b> — direct parent</span></div>
          <div className="gtb-gaps-row"><GlyphGap variant={variant}/><span><b>Dashed</b> — commits in between are hidden{gaps ? <span className="gpeek-dim"> · {gaps}×</span> : null}</span></div>
          <div className="gtb-gaps-row"><GlyphEnd variant={variant}/><span><b>End</b> — older history isn't in the revset{ends ? <span className="gpeek-dim"> · {ends}×</span> : null}</span></div>
          <div className="gpeek-desc">Stacks never span a gap. Hover a marker for details.</div>
          <div className="ggap-actions"><button className="ggap-btn" onClick={onShowAll}>Show <code>all()</code></button></div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { placeGapMarkers, gapCut, GapMark, GapEnd, GapPeek, GapLegend });
})();
