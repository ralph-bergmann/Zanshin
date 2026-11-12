import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";
import { zsDiffLine, zsDiffText, zsDiffRow, zsDiffDigits } from "./DiffView.jsx";

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
    if (l.t === "ctx") { rows.push([l.l == null ? null : cell([l], "ctx", true, l.l), l.r == null ? null : cell([l], "ctx", false, l.r)]); i++; continue; }
    const run = [];
    while (i < ls.length && ls[i].t !== "ctx" && ls[i].t !== "hdr") run.push(ls[i++]);
    const lefts = cells(run, true), rights = cells(run, false);
    for (let k = 0; k < Math.max(lefts.length, rights.length); k++) rows.push([lefts[k] || null, rights[k] || null]);
  }
  return rows;
}

// Numbers for git-sigil lines (no numbers of their own), counted from oldStart / newStart.
function zsNumbered(ls, oldStart, newStart) {
  let l = oldStart, r = newStart;
  return ls.map((x) => {
    if (x.l != null || x.r != null || x.t === "hdr") return x;
    const n = { ...x };
    if (x.t !== "add") n.l = l++;
    if (x.t !== "rem") n.r = r++;
    return n;
  });
}

// DiffHunk — one hunk: a header (checkbox · @@ range · enclosing context · +/− · grip) over its color-words lines, unified
// (a left and a right number column, then the text) or side by side (whole lines per side, each cell with its number).
// Selected hunks get the moon header and a 2px moon edge; they are what Commit / Split take. Mutable hunks can be dragged
// onto another change. Changed words are marked as in DiffView, in both layouts; a side-by-side cell clips its marks.
export function DiffHunk({ range, oldStart = 1, newStart = 1, context, lines = [], mode = "unified", selectable = false, selected = false, lifted = false, onToggle, onGrab, className = "" }) {
  const ls = zsNumbered(lines.map(zsDiffLine).filter((l) => l.t !== "hunk"), oldStart, newStart);
  const changed = ls.filter((l) => l.t !== "ctx" && l.t !== "hdr");
  const a = new Set(changed.map((l) => l.r).filter((n) => n != null)).size;
  const r = new Set(changed.map((l) => l.l).filter((n) => n != null)).size;
  const span = (side, start) => {
    const ns = ls.map((l) => l[side]).filter((n) => n != null);
    return ns.length ? [ns[0], Math.max(...ns) - ns[0] + 1] : [start, 0];
  };
  const [ol, oc] = span("l", oldStart), [nl, nc] = span("r", newStart);
  const head = range || "@@ −" + ol + "," + oc + " +" + nl + "," + nc + " @@";
  const body = mode !== "split"
    ? ls.map(zsDiffRow)
    : zsDiffSides(ls).map((row, k) => (
        <div key={k} className={"zs-diff-row" + (row.length === 1 ? " hdr" : "")}>
          {row.map((c, j) => (
            <div key={j} className={"zs-diff-side " + (c ? c.t : "empty")}>
              {c && c.t !== "hdr" && <span className="ln">{c.n}</span>}
              <span className="tx">{c ? zsDiffText(c) : ""}</span>
            </div>
          ))}
        </div>
      ));
  return (
    <div className={["zs-hunk", selected && "is-sel", lifted && "is-lifted", className].filter(Boolean).join(" ")}>
      <div className={"zs-hunk-hd" + (onGrab ? " is-grab" : "")} onPointerDown={onGrab} title={onGrab ? "Drag onto a change to move this hunk there" : undefined}>
        {selectable && <Checkbox checked={selected} onChange={onToggle} label={selected ? "Deselect hunk" : "Select hunk"} />}
        <code className="zs-hunk-range">{head}</code>
        {context && <span className="zs-hunk-ctx">{context}</span>}
        <span className="zs-hunk-stat">{a > 0 && <span className="a">+{a}</span>}{r > 0 && <span className="r">−{r}</span>}</span>
        {onGrab && <Icon name="grip" size="xs" className="zs-hunk-grip" style={{ height: 12 }} />}
      </div>
      <div className={"zs-diff-body" + (mode === "split" ? " zs-diff-split" : "")} style={{ "--ln": zsDiffDigits(ls) + "ch" }}>{body}</div>
    </div>
  );
}
