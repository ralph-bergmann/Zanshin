import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";

// DiffView — the diff block on the quiet code surface: a toolbar (path, layout toggle, Viewed) over hunks or plain lines.
// lines: strings with a git sigil ("+…", "-…", "@@…", " …") or objects { t: "add" | "rem" | "hunk" | "ctx", s, runs? }.
// children (DiffHunk elements) replace `lines`. viewed folds the body away into one green line.
// Changed words: one line per side, each with its sigil; git's delimiters mark the changed runs, "[-…-]" only on a removed
// line, "{+…+}" only on an added one. They become runs ([text, changed]); a line whose unchanged text is only blanks keeps
// none (its line fill says it all). A string has no escape: code holding "[-", "-]", "{+" or "+}" goes in the object form.
export function zsDiffLine(l) {
  if (typeof l !== "string") return l;
  if (l.startsWith("@@")) return { t: "hunk", s: l };
  if (l[0] !== "+" && l[0] !== "-") return { t: "ctx", s: l[0] === " " ? l.slice(1) : l };
  const t = l[0] === "+" ? "add" : "rem";
  const runs = l.slice(1).split(t === "add" ? /\{\+|\+\}/ : /\[-|-\]/).map((s, i) => [s, i % 2 === 1]).filter(([s]) => s);
  const s = runs.map(([x]) => x).join("");
  return runs.some(([, w]) => w) && runs.some(([x, w]) => !w && x.trim()) ? { t, s, runs } : { t, s };
}

// A line's text: each changed run a .w mark — the stronger tint of the line's hue, the line's full height, --text glyphs.
// Without runs (or with an empty list) it is the plain text.
export function zsDiffText(l) {
  return l.runs && l.runs.length ? l.runs.map(([s, w], i) => (w ? <span key={i} className="w">{s}</span> : s)) : l.s;
}

export function DiffView({ file, tools, lines = [], maxHeight, viewed, onViewedChange, children, className = "" }) {
  const toggle = onViewedChange && (
    <button type="button" role="checkbox" aria-checked={!!viewed} className={"zs-viewed" + (viewed ? " is-on" : "")} onClick={() => onViewedChange(!viewed)} title={viewed ? "Mark as not viewed" : "Mark as viewed"}>
      <Checkbox presentational size="sm" tone="add" checked={!!viewed} />
      <span>Viewed</span>
    </button>
  );
  return (
    <div className={["zs-diff", viewed && "is-viewed", className].filter(Boolean).join(" ")}>
      {(file || tools || toggle) && (
        <div className="zs-diff-bar">
          <span className="zs-diff-file" title={file}>{file}</span>
          {tools}
          {toggle}
        </div>
      )}
      {viewed && onViewedChange ? (
        <button type="button" className="zs-diff-collapsed" onClick={() => onViewedChange(false)}><Icon name="check" size="sm" /><span>Viewed — diff folded away. Click to show it again.</span></button>
      ) : children ? (
        <div className="zs-diff-hunks">{children}</div>
      ) : (
        <div className="zs-diff-body" style={{ maxHeight }}>
          {lines.map(zsDiffLine).map((l, i) =>
            l.t === "hunk" ? (
              <div key={i} className="zs-diff-hunk">{l.s}</div>
            ) : (
              <div key={i} className={"zs-diff-line " + l.t}>
                <span className="sg">{l.t === "add" ? "+" : l.t === "rem" ? "−" : " "}</span>
                <span className="tx">{zsDiffText(l)}</span>
              </div>
            )
          )}
        </div>
      )}
    </div>
  );
}
