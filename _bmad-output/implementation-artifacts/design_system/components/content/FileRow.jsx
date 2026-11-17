import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";

// FileRow — one changed file in the inspector's Changes list (Story 10.39, calmed in Story 10.42): the name first, then its quiet word —
// "new" (A), "deleted" (D), "from <old>" (R / C with from: the old name, the old path when the folder changed), nothing for a
// modification — then (flat) its folder dimmed and cut in its middle: the head gives way first, then the last folder, then the name
// with its word. No status letter, no +/− counts. selectable reserves a 22 px check column at the row's left edge; inside a pane with
// .zs-check-reveal its unchecked box shows only on hover or focus. viewed shows a green check and dims name and folder; lifted = being
// dragged. tree: the name only, indented 14 × depth + 20 (after the check column, else after 8 px). A folder row of the tree: pass open —
// the folder glyph open or closed (no chevron, no count), then the name (a joined chain reads "a/b/c"); indented 14 × depth.
// masked (Story 10.49): a file mask hides the row and it shows anyway — the row at .55, eye-off after the name.
export function FileRow({ status = "M", path = "", from, name, folder, tree = false, depth = 0, open, selected = false, viewed = false, masked = false, lifted = false, selectable = false, checked = false, mixed = false, onCheck, onClick, className = "", ...rest }) {
  const isDir = open !== undefined;
  const file = name ?? path.split("/").pop();
  const dir = folder ?? (path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "");
  const cut = dir.lastIndexOf("/", dir.length - 2);
  // the folder of path itself, never the folder display prop: same folder → the old name only
  const folderOf = (p) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/") + 1) : "");
  const note = isDir ? null
    : status === "A" ? <span className="zs-file-note is-new">new</span>
    : status === "D" ? <span className="zs-file-note is-del">deleted</span>
    : (status === "R" || status === "C") && from ? <span className="zs-file-note is-from">from {folderOf(from) === folderOf(path) ? from.split("/").pop() : from}</span>
    : null;
  const indent = isDir ? depth * 14 : tree ? depth * 14 + 20 : 0;
  return (
    <div role={tree || isDir ? "treeitem" : "listitem"} aria-expanded={isDir ? open : undefined} tabIndex={0}
      className={["zs-file", isDir && "is-dir", selectable && "has-gut", selected && "is-sel", viewed && "is-viewed", masked && "is-masked", lifted && "is-lifted", className].filter(Boolean).join(" ")}
      onClick={onClick} onKeyDown={(e) => { if (onClick && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); onClick(e); } }} title={masked ? (path || file) + " · hidden by a file mask" : from ? from + " → " + path : path || file} {...rest}>
      {selectable && <span className="zs-file-gut"><Checkbox size="sm" checked={checked} mixed={mixed} onChange={onCheck} label={"Select " + file} /></span>}
      <span className="zs-file-ind" style={indent ? { paddingLeft: indent } : undefined}>
        {isDir && <span className="zs-file-fold"><Icon name={open ? "folder-open" : "folder"} size="md" /></span>}
        <span className="zs-file-name">{file}{note}{masked && !isDir && <span className="zs-file-mask" aria-label="hidden by a file mask"><Icon name="eye-off" size="sm" /></span>}</span>
        {!tree && !isDir && dir && <span className="zs-file-dir"><span className="h">{dir.slice(0, cut + 1)}</span><span className="t">{dir.slice(cut + 1)}</span></span>}
      </span>
      {viewed && <span className="zs-file-vw" title="Viewed"><Icon name="check" size="xs" /></span>}
    </div>
  );
}
