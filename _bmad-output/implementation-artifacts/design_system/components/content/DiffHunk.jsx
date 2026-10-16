import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";
import { zsDiffLine } from "./DiffView.jsx";

// DiffHunk — one hunk: a header (checkbox · @@ range · enclosing context · +/− · grip) over its lines, unified or side by side.
// Selected hunks get the moon header and a 2px moon edge; they are what Commit / Split take. Mutable hunks can be dragged onto another change.
export function DiffHunk({ range, oldStart = 1, newStart = 1, context, lines = [], mode = "unified", selectable = false, selected = false, lifted = false, onToggle, onGrab, className = "" }) {
  const ls = lines.map(zsDiffLine).filter((l) => l.t !== "hunk");
  const a = ls.filter((l) => l.t === "add").length, r = ls.filter((l) => l.t === "rem").length;
  const head = range || "@@ −" + oldStart + "," + (ls.length - a) + " +" + newStart + "," + (ls.length - r) + " @@";
  let body;
  if (mode !== "split") {
    body = ls.map((l, i) => (
      <div key={i} className={"zs-diff-line " + l.t}><span className="sg">{l.t === "add" ? "+" : l.t === "rem" ? "−" : " "}</span><span className="tx">{l.s}</span></div>
    ));
  } else {
    const rows = [];
    for (let i = 0; i < ls.length;) {
      if (ls[i].t === "ctx") { rows.push([ls[i], ls[i]]); i++; continue; }
      const rem = [], add = [];
      while (i < ls.length && ls[i].t === "rem") rem.push(ls[i++]);
      while (i < ls.length && ls[i].t === "add") add.push(ls[i++]);
      for (let k = 0; k < Math.max(rem.length, add.length); k++) rows.push([rem[k] || null, add[k] || null]);
    }
    body = rows.map(([x, y], k) => (
      <div key={k} className="zs-diff-row">
        <div className={"zs-diff-side " + (x ? x.t : "empty")}><span className="tx">{x ? x.s : ""}</span></div>
        <div className={"zs-diff-side " + (y ? y.t : "empty")}><span className="tx">{y ? y.s : ""}</span></div>
      </div>
    ));
  }
  return (
    <div className={["zs-hunk", selected && "is-sel", lifted && "is-lifted", className].filter(Boolean).join(" ")}>
      <div className={"zs-hunk-hd" + (onGrab ? " is-grab" : "")} onPointerDown={onGrab} title={onGrab ? "Drag onto a change to move this hunk there" : undefined}>
        {selectable && <Checkbox checked={selected} onChange={onToggle} label={selected ? "Deselect hunk" : "Select hunk"} />}
        <code className="zs-hunk-range">{head}</code>
        {context && <span className="zs-hunk-ctx">{context}</span>}
        <span className="zs-hunk-stat">{a > 0 && <span className="a">+{a}</span>}{r > 0 && <span className="r">−{r}</span>}</span>
        {onGrab && <Icon name="grip" size="xs" className="zs-hunk-grip" style={{ height: 12 }} />}
      </div>
      <div className={"zs-diff-body" + (mode === "split" ? " zs-diff-split" : "")}>{body}</div>
    </div>
  );
}
