import React from "react";
import { Icon } from "../brand/Icon.jsx";

// DiffView — the diff block on the quiet code surface: a toolbar (path, layout toggle, Viewed) over hunks or plain lines.
// lines: strings with a git sigil ("+…", "-…", "@@…", " …") or objects { t: "add" | "rem" | "hunk" | "ctx", s }.
// children (DiffHunk elements) replace `lines`. viewed folds the body away into one green line.
export function zsDiffLine(l) {
  if (typeof l !== "string") return l;
  if (l.startsWith("@@")) return { t: "hunk", s: l };
  if (l[0] === "+") return { t: "add", s: l.slice(1) };
  if (l[0] === "-") return { t: "rem", s: l.slice(1) };
  return { t: "ctx", s: l[0] === " " ? l.slice(1) : l };
}

export function DiffView({ file, tools, lines = [], maxHeight, viewed, onViewedChange, children, className = "" }) {
  const toggle = onViewedChange && (
    <button type="button" role="checkbox" aria-checked={!!viewed} className={"zs-viewed" + (viewed ? " is-on" : "")} onClick={() => onViewedChange(!viewed)} title={viewed ? "Mark as not viewed" : "Mark as viewed"}>
      <span className={"zs-viewed-box" + (viewed ? " is-on" : "")}>{viewed && <Icon name="check" size={10} />}</span>
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
        <button type="button" className="zs-diff-collapsed" onClick={() => onViewedChange(false)}><Icon name="check" size={11} /><span>Viewed — diff folded away. Click to show it again.</span></button>
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
                <span className="tx">{l.s}</span>
              </div>
            )
          )}
        </div>
      )}
    </div>
  );
}
