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
    return { t, n, s, ws: group.some((l) => l.ws) || undefined, runs: runs.some(([x, k]) => !k && x.trim()) ? runs : undefined };
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
    if (l.t === "fold") { rows.push({ fold: l }); i++; continue; }
    if (l.t === "ctx") { rows.push([l.l == null ? null : cell([l], "ctx", true, l.l), l.r == null ? null : cell([l], "ctx", false, l.r)]); i++; continue; }
    const run = [];
    while (i < ls.length && ls[i].t !== "ctx" && ls[i].t !== "hdr" && ls[i].t !== "fold") run.push(ls[i++]);
    const lefts = cells(run, true), rights = cells(run, false);
    for (let k = 0; k < Math.max(lefts.length, rights.length); k++) rows.push([lefts[k] || null, rights[k] || null]);
  }
  return rows;
}

// Numbers for git-sigil lines (no numbers of their own), counted from oldStart / newStart.
function zsNumbered(ls, oldStart, newStart) {
  let l = oldStart, r = newStart;
  return ls.map((x) => {
    if (x.l != null || x.r != null || x.t === "hdr" || x.t === "fold") return x;
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
// wordMarks={false} (or a DiffView around it with wordMarks={false}) draws them without their tint.
// Parts (2026-11-14, Story 10.38, sync #26): `parts` gives each line its part (jj's diff-editor section; null for context). A
// selectable hunk of more than one part shows "N parts" in its header and a 22px gutter before the numbers (side by side: leading the
// row) with a checkbox on each part's first line; `picked` lists the picked parts — some of them: the header on --accent at 12 % and the
// hunk checkbox mixed; a picked part's lines carry the 2px edge. Unified, the gutter and numbers stay pinned at the visible left edge
// while the text scrolls under them (a DiffView around the hunks scrolls them as one unit).
// Whitespace ignored (2026-11-14, Story 10.33, sync #26): a line object with `ws: "picked" | "opened"` changed only in whitespace and
// shows because its part is picked or opened — its text at .62; unified, with a right number it carries the pill "whitespace only"
// ("whitespace only · Hide" while only opened, onHide). `{ t: "fold", n }` is a part made only of such lines, folded into one hatched
// row "⋯ N lines changed whitespace only · Show" (onShow), full width, its checkbox in the gutter while the hunk is selectable.
export function DiffHunk({ range, oldStart = 1, newStart = 1, context, lines = [], wordMarks = true, mode = "unified", selectable = false, selected = false, lifted = false, onToggle, onGrab, parts, picked: pickedIn = [], onTogglePart, onShow, onHide, className = "" }) {
  const ls = zsNumbered(lines.map(zsDiffLine).filter((l) => l.t !== "hunk"), oldStart, newStart);
  const partOf = parts ? lines.filter((l) => !(typeof l === "string" && l.startsWith("@@"))).map((_, i) => parts[i] ?? null) : [];
  const allParts = [...new Set(partOf.filter((p) => p != null))];
  const count = allParts.length;
  const showParts = selectable && count > 1;
  // A selected hunk without its own part picks has every part picked.
  const picked = showParts && selected && !pickedIn.length ? allParts : pickedIn;
  const some = showParts && picked.length > 0 && picked.length < count;
  const all = selected || (showParts && picked.length === count);
  const seen = new Set();
  // the gutter leads every row while the hunk shows its parts, or a folded part takes a pick
  const gut = showParts || (selectable && ls.some((l) => l.t === "fold"));
  const gutter = (p) => gut && (
    <span className="zs-diff-gut">{showParts && p != null && !seen.has(p) && seen.add(p) &&
      <Checkbox size="sm" checked={picked.includes(p)} onChange={() => onTogglePart && onTogglePart(p)} label={picked.includes(p) ? "Unpick these lines" : "Pick these lines"} />}</span>
  );
  const pick = (p) => (showParts ? p != null && picked.includes(p) : all) ? " is-pick" : "";
  const fold = (l, p, k, side) => {
    if (p != null) seen.add(p);
    return (
      <div key={k} className={"zs-diff-fold" + (side ? " is-side" : "")}>
        {side ? gut && <span className="zs-diff-gut">{selectable && <Checkbox size="sm" checked={false} onChange={() => onTogglePart && onTogglePart(p)} label="Pick these whitespace-only lines" />}</span>
          : <span className="zs-diff-pin">{gut && <span className="zs-diff-gut">{selectable && <Checkbox size="sm" checked={false} onChange={() => onTogglePart && onTogglePart(p)} label="Pick these whitespace-only lines" />}</span>}<span className="ln l" /><span className="ln r" /></span>}
        <button type="button" className="zs-fold-tx" title="Show these lines" onClick={() => onShow && onShow(p)}>⋯ {l.n} {l.n === 1 ? "line" : "lines"} changed whitespace only · Show</button>
      </div>
    );
  };
  const tag = (l, p) => l.ws && l.r != null && (l.ws === "opened"
    ? <button type="button" className="zs-ws-tag" title="Hide the whitespace-only lines again" onClick={() => onHide && onHide(p)}>whitespace only · Hide</button>
    : <span className="zs-ws-tag" title="Shown because its part is picked: a pick takes every line of its part">whitespace only</span>);
  const changed = ls.filter((l) => l.t !== "ctx" && l.t !== "hdr" && l.t !== "fold");
  const a = new Set(changed.map((l) => l.r).filter((n) => n != null)).size;
  const r = new Set(changed.map((l) => l.l).filter((n) => n != null)).size;
  const span = (side, start) => {
    const ns = ls.map((l) => l[side]).filter((n) => n != null);
    return ns.length ? [ns[0], Math.max(...ns) - ns[0] + 1] : [start, 0];
  };
  const [ol, oc] = span("l", oldStart), [nl, nc] = span("r", newStart);
  const head = range || "@@ −" + ol + "," + oc + " +" + nl + "," + nc + " @@";
  const body = mode !== "split"
    ? ls.map((l, i) => (l.t === "fold" ? fold(l, partOf[i], i, false) : (
        <div key={i} className={"zs-diff-line " + l.t + pick(partOf[i]) + (l.ws ? " is-ws" : "")}>
          <span className="zs-diff-pin">{gutter(partOf[i])}<span className="ln l">{l.t !== "hdr" ? l.l ?? "" : ""}</span><span className="ln r">{l.t !== "hdr" ? l.r ?? "" : ""}</span></span>
          <span className="tx">{zsDiffText(l)}</span>{tag(l, partOf[i])}
        </div>
      )))
    : zsDiffSides(ls).map((row, k) => {
        if (row.fold) return fold(row.fold, partOf[ls.indexOf(row.fold)], k, true);
        // a row's part: the part of the first changed line holding one of its numbers
        const p = row.length === 1 ? null : (() => { for (const c of row) { if (!c || c.t === "ctx") continue; const i = ls.findIndex((l) => l.t !== "ctx" && (c.t === "rem" ? l.l === c.n : l.r === c.n)); if (i >= 0 && partOf[i] != null) return partOf[i]; } return null; })();
        return (
        <div key={k} className={"zs-diff-row" + (row.length === 1 ? " hdr" : "") + (gut ? " has-gut" + pick(p) : "")}>
          {gutter(p)}
          {row.map((c, j) => (
            <div key={j} className={"zs-diff-side " + (c ? c.t : "empty") + (c && c.ws ? " is-ws" : "")}>
              {c && c.t !== "hdr" && <span className="ln">{c.n}</span>}
              <span className="tx">{c ? zsDiffText(c) : ""}</span>
            </div>
          ))}
        </div>
        );
      });
  return (
    <div className={["zs-hunk", all && "is-sel", some && "is-some", lifted && "is-lifted", !wordMarks && "no-word-marks", className].filter(Boolean).join(" ")}>
      <div className={"zs-hunk-hd" + (onGrab ? " is-grab" : "")} onPointerDown={onGrab} title={onGrab ? "Drag onto a change to move this hunk there" : undefined}>
        {selectable && <Checkbox checked={all} mixed={some} onChange={onToggle} label={all ? "Deselect hunk" : "Select hunk"} />}
        <code className="zs-hunk-range">{head}</code>
        {showParts && <span className="zs-hunk-parts" title="Parts you can pick on their own">{count} parts</span>}
        {context && <span className="zs-hunk-ctx">{context}</span>}
        <span className="zs-hunk-stat">{a > 0 && <span className="a">+{a}</span>}{r > 0 && <span className="r">−{r}</span>}</span>
        {onGrab && <Icon name="grip" size="xs" className="zs-hunk-grip" style={{ height: 12 }} />}
      </div>
      <div className={"zs-diff-body" + (mode === "split" ? " zs-diff-split" : "")} style={{ "--ln": zsDiffDigits(ls) + "ch" }}>{body}</div>
    </div>
  );
}
