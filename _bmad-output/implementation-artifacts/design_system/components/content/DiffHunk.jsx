import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";
import { zsDiffLine, zsDiffText, zsDiffDigits } from "./DiffView.jsx";

// Side by side, rebuilt from the color-words lines so each side shows whole lines: a context line is one row (left cell its
// equal and removed runs with its left number, right cell its equal and added runs with its right number); a run of
// removed, added and changed lines gives one left cell per distinct left number and one right cell per distinct right
// number, paired row by row; a header is one full-width row. Under a "-------" conflict term the left side keeps the
// added runs.
export function zsDiffSides(ls) {
  const rows = [];
  let swapped = false;
  const cell = (group, t, left, n) => {
    const own = left !== swapped ? "rem" : "add";
    const runs = [];
    for (const l of group) {
      for (const [s, k] of l.runs || [[l.s, l.t === "chg" ? null : l.t === "ctx" ? null : l.t]]) {
        if (k && k !== own) continue;
        if (runs.length && runs[runs.length - 1][1] === k) runs[runs.length - 1][0] += s;
        else runs.push([s, k]);
      }
    }
    const s = runs.map(([x]) => x).join("");
    return { t, n, s, runs: runs.some(([x, k]) => !k && x.trim()) ? runs : undefined };
  };
  const cells = (run, left) => {
    const groups = new Map();
    for (const l of run) {
      const n = left ? l.l : l.r;
      if (n == null) continue;
      if (!groups.has(n)) groups.set(n, []);
      groups.get(n).push(l);
    }
    return [...groups].map(([n, group]) => cell(group, left ? "rem" : "add", left, n));
  };
  for (let i = 0; i < ls.length;) {
    const l = ls[i];
    if (l.t === "hdr") { swapped = l.s.startsWith("-------"); rows.push([l]); i++; continue; }
    if (zsDiffGap(l)) { rows.push({ fold: l }); i++; continue; }
    if (l.t === "ctx") { rows.push([l.l == null ? null : cell([l], "ctx", true, l.l), l.r == null ? null : cell([l], "ctx", false, l.r)]); i++; continue; }
    const run = [];
    while (i < ls.length && ls[i].t !== "ctx" && ls[i].t !== "hdr" && !zsDiffGap(ls[i])) run.push(ls[i++]);
    const lefts = cells(run, true), rights = cells(run, false);
    for (let k = 0; k < Math.max(lefts.length, rights.length); k++) rows.push([lefts[k] || null, rights[k] || null]);
  }
  return rows;
}

// A row for hidden lines: unchanged lines (Story 10.43), or whitespace-only lines (Story 10.41) — a gap, or a whitespace-only part's fold.
const zsDiffGap = (l) => l.t === "unchanged" || l.t === "gap" || l.t === "fold";

// Numbers for git-sigil lines (no numbers of their own), counted from oldStart / newStart.
function zsNumbered(ls, oldStart, newStart) {
  let l = oldStart, r = newStart;
  return ls.map((x) => {
    if (x.l != null || x.r != null || x.t === "hdr" || zsDiffGap(x)) return x;
    const n = { ...x };
    if (x.t !== "add") n.l = l++;
    if (x.t !== "rem") n.r = r++;
    return n;
  });
}

// How many hidden unchanged lines one arrow opens.
const ZS_GAP_STEP = 20;

// DiffHunk — one hunk's color-words lines, unified (a left and a right number column, then the text) or side by side (whole
// lines per side, each cell with its number). No header (2026-11-15, Story 10.43, Calm Inspector Study): hunks follow each other
// with a 1px line, or a gap row between them. Changed words are marked as in DiffView, in both layouts; a side-by-side cell clips
// its marks. wordMarks={false} (or a DiffView around it with wordMarks={false}) draws them without their tint.
// Parts (Stories 10.38, 10.43): `parts` gives each line its part (jj's diff-editor section; null for context; without `parts` the
// changed lines are one part, 0). A selectable hunk shows a 22px gutter before the numbers (side by side: leading the row) with one
// checkbox per part, on the part's first row — also when the hunk has one part; `picked` lists the picked parts, whose rows carry a
// 2px --accent-line bar on the left edge. While the pointer rests on a part's checkbox every row of that part shows the same bar.
// Unified, the gutter and numbers stay pinned at the visible left edge while the text scrolls under them.
// Gap rows: one quiet 26px band — the gutter (empty but for a fold's checkbox), the arrow columns over the numbers, the text, a button.
// `{ t: "unchanged", n, top, bottom }` stands for n hidden unchanged lines (Story 10.43): "N unchanged lines"; with onExpand,
// n ≤ 20 gets one ↕ "Show N lines", more gets ↓ "Show 20 lines below" (not on a top gap), ↑ "Show 20 lines above" (not on a
// bottom gap) and "Show all". Whitespace ignored (Story 10.41): `{ t: "gap", n, open, fixed }` stands for n whitespace-only lines jj
// skips — "N more lines with only whitespace changes" with Show (onShow); open, it stays above its lines, "N lines with only
// whitespace changes" with Hide (onHide; none when `fixed`, a pick keeps it open). `{ t: "fold", n, open, fixed }` is a part made only
// of such lines: the same band, hatched, its checkbox in the gutter; closed it reads "⋯ N lines changed whitespace only", then Show.
// Inside a pane marked .zs-check-reveal the arrows and buttons show only while the pointer or focus is in the pane.
export function DiffHunk({ oldStart = 1, newStart = 1, lines = [], wordMarks = true, mode = "unified", selectable = false, lifted = false, parts, picked = [], onTogglePart, onShow, onHide, onExpand, className = "" }) {
  const [hot, setHot] = React.useState(null);
  const ls = zsNumbered(lines.map(zsDiffLine).filter((l) => l.t !== "hunk"), oldStart, newStart);
  const partOf = parts
    ? lines.filter((l) => !(typeof l === "string" && l.startsWith("@@"))).map((_, i) => parts[i] ?? null)
    : ls.map((l) => (l.t === "ctx" || l.t === "hdr" || zsDiffGap(l) ? null : 0));
  const gut = selectable && partOf.some((p) => p != null);
  const seen = new Set();
  // the part's checkbox goes on its first row; resting the pointer on it lights every row of the part
  const gutter = (p, ws) => {
    if (!gut) return null;
    const first = p != null && !seen.has(p);
    if (first) seen.add(p);
    const on = picked.includes(p);
    return (
      <span className="zs-diff-gut" onMouseEnter={first ? () => setHot(p) : undefined} onMouseLeave={first ? () => setHot(null) : undefined}>
        {first && <Checkbox size="sm" checked={on} onChange={() => onTogglePart && onTogglePart(p)} label={(on ? "Unpick these " : "Pick these ") + (ws ? "whitespace-only lines" : "lines")} />}
      </span>
    );
  };
  const pick = (p) => (p == null ? "" : picked.includes(p) ? " is-pick" : hot === p ? " is-hot" : "");
  const nLines = (n) => n + " " + (n === 1 ? "line" : "lines");
  const gapRow = (l, p, k) => {
    const btn = (icon, title, how) => <button key={how} type="button" className="zs-gap-btn" title={title} aria-label={title} onClick={() => onExpand(l, how)}><Icon name={icon} size={14} /></button>;
    const small = l.n <= ZS_GAP_STEP;
    let arrows = null, text, action = null;
    if (l.t === "unchanged") {
      text = l.n + " unchanged " + (l.n === 1 ? "line" : "lines");
      if (onExpand) {
        arrows = small ? btn("updown", "Show " + nLines(l.n), "all")
          : [!l.top && btn("chevron-down", "Show " + ZS_GAP_STEP + " lines below", "down"), !l.bottom && btn("chevron-up", "Show " + ZS_GAP_STEP + " lines above", "up")];
        if (!small) action = <button type="button" className="zs-gap-all" onClick={() => onExpand(l, "all")}>Show all</button>;
      }
    } else if (l.t === "fold" && !l.open) {
      text = "⋯ " + nLines(l.n) + " changed whitespace only";
      action = <button type="button" className="zs-gap-all" title="Show these lines" onClick={() => onShow && onShow(l, p)}>Show</button>;
    } else {
      text = (l.open ? nLines(l.n) : l.n + " more " + (l.n === 1 ? "line" : "lines")) + " with only whitespace changes";
      if (!l.fixed) action = <button type="button" className="zs-gap-all" title={l.open ? "Hide these lines again" : "Show these lines"} onClick={() => (l.open ? onHide : onShow)?.(l, p)}>{l.open ? "Hide" : "Show"}</button>;
    }
    return (
      <div key={k} className={"zs-diff-gap" + (l.t === "fold" ? " is-fold" : "") + pick(p)}>
        <span className="zs-diff-pin">{gutter(p, true)}<span className="zs-gap-arrows">{arrows}</span></span>
        {typeof text === "string" ? <span className="zs-gap-tx">{text}</span> : text}
        {action}
      </div>
    );
  };
  const body = mode !== "split"
    ? ls.map((l, i) => (zsDiffGap(l) ? gapRow(l, partOf[i], i) : (
        <div key={i} className={"zs-diff-line " + l.t + pick(partOf[i])}>
          <span className="zs-diff-pin">{gutter(partOf[i])}<span className="ln l">{l.t !== "hdr" ? l.l ?? "" : ""}</span><span className="ln r">{l.t !== "hdr" ? l.r ?? "" : ""}</span></span>
          <span className="tx">{zsDiffText(l)}</span>
        </div>
      )))
    : zsDiffSides(ls).map((row, k) => {
        if (row.fold) return gapRow(row.fold, partOf[ls.indexOf(row.fold)], k);
        // a row's part: the part of the first changed line holding one of its numbers
        const p = row.length === 1 ? null : (() => { for (const c of row) { if (!c || c.t === "ctx") continue; const i = ls.findIndex((l) => l.t !== "ctx" && (c.t === "rem" ? l.l === c.n : l.r === c.n)); if (i >= 0 && partOf[i] != null) return partOf[i]; } return null; })();
        return (
        <div key={k} className={"zs-diff-row" + (row.length === 1 ? " hdr" : "") + (gut ? " has-gut" + pick(p) : "")}>
          {gutter(p)}
          {row.map((c, j) => (
            <div key={j} className={"zs-diff-side " + (c ? c.t : "empty")}>
              {c && c.t !== "hdr" && <span className="ln">{c.n}</span>}
              <span className="tx">{c ? zsDiffText(c) : ""}</span>
            </div>
          ))}
        </div>
        );
      });
  return (
    <div className={["zs-hunk", lifted && "is-lifted", !wordMarks && "no-word-marks", className].filter(Boolean).join(" ")}>
      <div className={"zs-diff-body" + (mode === "split" ? " zs-diff-split" : "")} style={{ "--ln": zsDiffDigits(ls) + "ch" }}>{body}</div>
    </div>
  );
}
