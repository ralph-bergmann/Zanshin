import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";

// FileRow — one changed file in the inspector's Changes list. Status M/A/D, path truncates from the left (the filename stays visible), +/− counts.
// selectable adds a Checkbox (pick files for commit / split); viewed shows a green check and dims the path; lifted = being dragged elsewhere.
export function FileRow({ status = "M", path = "", added, removed, selected = false, viewed = false, lifted = false, selectable = false, checked = false, mixed = false, onCheck, onClick, className = "", ...rest }) {
  const name = path.split("/").pop();
  return (
    <div role="listitem" tabIndex={0} className={["zs-file", selected && "is-sel", viewed && "is-viewed", lifted && "is-lifted", className].filter(Boolean).join(" ")}
      onClick={onClick} onKeyDown={(e) => { if (onClick && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); onClick(e); } }} title={path} {...rest}>
      {selectable && <Checkbox checked={checked} mixed={mixed} onChange={onCheck} label={"Select " + name} />}
      <span className={"zs-file-status s-" + status}>{status}</span>
      <span className="zs-file-path"><span>{path}</span></span>
      {viewed && <span className="zs-file-vw" title="Viewed"><Icon name="check" size={10} /></span>}
      <span className="zs-file-stat">
        {added > 0 && <span className="a">+{added}</span>}
        {removed > 0 && <span className="r">−{removed}</span>}
      </span>
    </div>
  );
}
