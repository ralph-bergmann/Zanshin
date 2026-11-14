import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";

// FileRow — one changed file in the inspector's Changes list (Story 10.39): the name first, then (flat) its folder dimmed and cut in its
// middle — the head gives way first, then the last folder, then the name. Status M/R moon, A/C green, D red; +/− counts.
// selectable adds a Checkbox (pick files for commit / split); viewed shows a green check and dims name and folder; lifted = being dragged.
// tree: the name only, indented 8 + 14 × depth + 18. A folder row of the tree: pass open (and count) — chevron, three-state Checkbox,
// folder glyph, name (a joined chain reads "a/b/c"), the count pill and the summed counts; indented 8 + 14 × depth.
export function FileRow({ status = "M", path = "", name, folder, tree = false, depth = 0, open, count, added, removed, selected = false, viewed = false, lifted = false, selectable = false, checked = false, mixed = false, onCheck, onClick, className = "", ...rest }) {
  const isDir = open !== undefined;
  const file = name ?? path.split("/").pop();
  const dir = folder ?? (path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "");
  const cut = dir.lastIndexOf("/", dir.length - 2);
  const pad = tree || isDir ? { paddingLeft: 8 + depth * 14 + (isDir ? 0 : 18) } : undefined;
  return (
    <div role={tree || isDir ? "treeitem" : "listitem"} aria-expanded={isDir ? open : undefined} tabIndex={0} style={pad}
      className={["zs-file", isDir && "is-dir", selected && "is-sel", viewed && "is-viewed", lifted && "is-lifted", className].filter(Boolean).join(" ")}
      onClick={onClick} onKeyDown={(e) => { if (onClick && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); onClick(e); } }} title={path || file} {...rest}>
      {isDir && <span className="zs-file-chev"><Icon name={open ? "chevron-down" : "chevron-right"} size="xs" /></span>}
      {selectable && <Checkbox checked={checked} mixed={mixed} onChange={onCheck} label={"Select " + file} />}
      {isDir ? <span className="zs-file-fold"><Icon name="folder" size="sm" /></span> : <span className={"zs-file-status s-" + status}>{status}</span>}
      <span className="zs-file-name">{file}</span>
      {!tree && !isDir && dir && <span className="zs-file-dir"><span className="h">{dir.slice(0, cut + 1)}</span><span className="t">{dir.slice(cut + 1)}</span></span>}
      {isDir && count !== undefined && <span className="zs-file-count">{count}</span>}
      {viewed && <span className="zs-file-vw" title="Viewed"><Icon name="check" size="xs" /></span>}
      <span className="zs-file-stat">
        {added > 0 && <span className="a">+{added}</span>}
        {removed > 0 && <span className="r">−{removed}</span>}
      </span>
    </div>
  );
}
