import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";
import { MenuButton } from "../actions/MenuButton.jsx";

// DiffView — the diff block on the quiet code surface: a toolbar (path, layout toggle, Viewed) over hunks or plain lines.
// The lines are jj diff's default color-words lines: each row shows its left and right line number, then its text.
// lines: strings "<kind><left>:<right>|<text>" — kind " " context, "-" removed (left only), "+" added (right only),
// "~" changed (an inlined line holding both sides' words), "#" a conflict header ("#|<<<<<<< Created conflict") —
// or objects { t: "ctx" | "rem" | "add" | "chg" | "hdr", l?, r?, s, runs? }. Changed words: "[-…-]" around a left-side
// run, "{+…+}" around a right-side one, on any line. They become runs ([text, "rem" | "add" | null]); a removed or
// added line whose unchanged text is only blanks keeps none (its fill says it all); a changed line always keeps them.
// Older git strings ("+…", "-…", " …", "@@…") still parse, without numbers. A string has no escape: code holding "[-",
// "-]", "{+" or "+}" goes in the object form.
export function zsDiffLine(l) {
  if (typeof l !== "string") {
    // The object form of before Story 5.10 had boolean runs: true is the line's own side.
    return l.runs ? { ...l, runs: l.runs.map(([s, k]) => [s, k === true ? l.t : k || null]) } : l;
  }
  if (l.startsWith("@@")) return { t: "hunk", s: l };
  if (l.startsWith("#|")) return { t: "hdr", s: l.slice(2) };
  const cw = /^([ ~+-])(\d*):(\d*)\|/.exec(l);
  const t = cw ? { " ": "ctx", "-": "rem", "+": "add", "~": "chg" }[cw[1]] : l[0] === "+" ? "add" : l[0] === "-" ? "rem" : "ctx";
  const body = cw ? l.slice(cw[0].length) : t === "ctx" && l[0] !== " " ? l : l.slice(1);
  const runs = [];
  for (const m of body.matchAll(/\[-([\s\S]*?)-\]|\{\+([\s\S]*?)\+\}|([^[{]+|[[{])/g)) {
    const [s, k] = m[1] != null ? [m[1], "rem"] : m[2] != null ? [m[2], "add"] : [m[3], null];
    if (!s) continue;
    if (runs.length && runs[runs.length - 1][1] === k) runs[runs.length - 1][0] += s;
    else runs.push([s, k]);
  }
  const line = { t, s: runs.map(([x]) => x).join("") };
  if (cw) {
    if (cw[2]) line.l = Number(cw[2]);
    if (cw[3]) line.r = Number(cw[3]);
  }
  const marked = runs.some(([, k]) => k) && (t === "chg" || runs.some(([x, k]) => !k && x.trim()));
  return marked ? { ...line, runs } : line;
}

// A line's text: each changed run a .w mark — the stronger tint of its side's hue (.w.rem / .w.add), the line's full
// height, --text glyphs; under .no-word-marks (Settings › Changed words off) no tint, the row's ink, and only a changed
// row keeps glyphs in the side's hue. Without runs (or with an empty list) it is the plain text.
export function zsDiffText(l) {
  return l.runs && l.runs.length ? l.runs.map(([s, k], i) => (k ? <span key={i} className={"w " + k}>{s}</span> : s)) : l.s;
}

// One unified row: the left and right number columns (outside the selection), then the text; a header spans the row.
export function zsDiffRow(l, i) {
  return (
    <div key={i} className={"zs-diff-line " + l.t}>
      {l.t !== "hdr" && <span className="ln l">{l.l ?? ""}</span>}
      {l.t !== "hdr" && <span className="ln r">{l.r ?? ""}</span>}
      <span className="tx">{zsDiffText(l)}</span>
    </div>
  );
}

// The number columns' width: the largest number's digits.
export function zsDiffDigits(ls) {
  return Math.max(1, ...ls.map((l) => String(Math.max(l.l || 0, l.r || 0)).length));
}

// The diff options menu (2026-11-14, Story 10.33): whitespace (an app setting) and context lines (jj's diff.color-words.context, user config).
const ZS_WS = [["show", "Show all whitespace", "jj diff"], ["amount", "Ignore changes in amount", "jj diff -b"], ["all", "Ignore all whitespace", "jj diff -w"]];
export function zsDiffOptionItems({ whitespace = "show", context = 3 }) {
  const ns = [...new Set([0, 1, 2, 3, 5, 10, 20, ...(context == null ? [] : [context])])].sort((a, b) => a - b);
  return [
    { header: "Whitespace" },
    ...ZS_WS.map(([id, label, cmd]) => ({ id: "ws:" + id, label, cmd, checked: whitespace === id, radio: true })),
    "sep", { header: "Context lines" },
    ...ns.map((n) => ({ id: "ctx:" + n, label: String(n), shortcut: n === 3 ? "jj's default" : undefined, checked: context === n, radio: true })),
    "sep", { note: "Every diff follows these. Context lines is jj's diff.color-words.context in your user config, as in Settings › General › Diffs. A picked part shows its hidden whitespace lines, so a commit holds nothing you didn't see." },
  ];
}

// The bar's path, name first (Story 10.39): the name (500) then the folder dimmed, cut like a FileRow's. With copyPath a flat button that
// copies it and shows "Copied" in --add for 1.3 s; without, plain text.
function ZsDiffPath({ file, copyPath }) {
  const [copied, setCopied] = React.useState(false);
  const name = file.split("/").pop();
  const dir = file.includes("/") ? file.slice(0, file.lastIndexOf("/") + 1) : "";
  const parts = [<span key="n" className="n">{name}</span>, dir && <span key="d" className="d">{dir}</span>];
  if (!copyPath) return <span className="zs-diff-file" title={file}>{parts}</span>;
  const copy = () => { if (navigator.clipboard) navigator.clipboard.writeText(copyPath); setCopied(true); setTimeout(() => setCopied(false), 1300); };
  return (
    <button type="button" className="zs-diff-file is-copy" onClick={copy} title={"Click to copy " + copyPath}>
      {parts}{copied && <span className="c">Copied</span>}
    </button>
  );
}

export function DiffView({ file, copyPath, tools, lines = [], wordMarks = true, maxHeight, viewed, onViewedChange, options, onOption, onlyWhitespace = false, children, className = "" }) {
  const toggle = onViewedChange && (
    <button type="button" role="checkbox" aria-checked={!!viewed} className={"zs-viewed" + (viewed ? " is-on" : "")} onClick={() => onViewedChange(!viewed)} title={viewed ? "Mark as not viewed" : "Mark as viewed"}>
      <Checkbox presentational size="sm" tone="add" checked={!!viewed} />
      <span>Viewed</span>
    </button>
  );
  // the diff options menu: the last control; its glyph --accent while a value is off its default
  const menu = options && (() => {
    const { whitespace = "show", context = 3 } = options;
    const ws = (ZS_WS.find(([id]) => id === whitespace) || ZS_WS[0])[1];
    const label = "Diff options — " + ws + ", " + (context == null ? "context lines unreadable" : context + (context === 1 ? " context line" : " context lines"));
    return <MenuButton iconOnly icon="view-options" variant="ghost" active={whitespace !== "show" || context !== 3} label={label} items={zsDiffOptionItems(options)} onSelect={onOption} />;
  })();
  const ls = lines.map(zsDiffLine);
  return (
    <div className={["zs-diff", viewed && "is-viewed", !wordMarks && "no-word-marks", className].filter(Boolean).join(" ")}>
      {(file || tools || toggle || menu) && (
        <div className="zs-diff-bar">
          {file ? <ZsDiffPath file={file} copyPath={copyPath} /> : <span className="zs-diff-file" />}
          {tools}
          {toggle}
          {menu}
        </div>
      )}
      {viewed && onViewedChange ? (
        <button type="button" className="zs-diff-collapsed" onClick={() => onViewedChange(false)}><Icon name="check" size="sm" /><span>Viewed — diff folded away. Click to show it again.</span></button>
      ) : onlyWhitespace ? (
        <div className="zs-diff-note">Only whitespace changed in this file.</div>
      ) : children ? (
        // the hunks scroll sideways as one unit, every line as wide as the widest (Story 10.38)
        <div className="zs-diff-hunks" style={{ maxHeight }}><div className="zs-diff-wide">{children}</div></div>
      ) : (
        <div className="zs-diff-body" style={{ maxHeight, "--ln": zsDiffDigits(ls) + "ch" }}>
          {ls.map((l, i) => (l.t === "hunk" ? <div key={i} className="zs-diff-hunk">{l.s}</div> : zsDiffRow(l, i)))}
        </div>
      )}
    </div>
  );
}
