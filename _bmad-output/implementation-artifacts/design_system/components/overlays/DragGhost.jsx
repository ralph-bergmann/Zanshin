import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { AtBadge } from "../graph/AtBadge.jsx";
import { zsProjectStatus } from "../content/ProjectRow.jsx";

// DragGhost — what is in your hand while dragging. kind: change (id + subject) · bookmark (pill) · diff (file status + name or a count) ·
// project / group (a row of the Projects tree: status dot or folder + label).
// Below it: the jj command a plain drop would run (moon-bordered) — for a list move, target: where it goes, in words (moon-bordered) —
// or a hint while nothing is targeted. Hidden once the DropMenu opens.
export function DragGhost({ kind = "change", id = "", subject, workingCopy = false, bookmark, rest, status = "M", label, added, removed, command, target, hint, className = "", style }) {
  let chip;
  if (kind === "project" || kind === "group") {
    const s = zsProjectStatus[status] || zsProjectStatus.clean;
    chip = (
      <div className="zs-ghost-card">
        {kind === "group" ? <Icon name="folder" size="md" /> : <span className="zs-proj-dot" style={{ background: s.color }}></span>}
        <span className="zs-ghost-subj">{label}</span>
      </div>
    );
  } else if (kind === "bookmark") {
    chip = (
      <div className="zs-ghost-card is-bm">
        <Icon name="bookmark" size="sm" />
        <span className="zs-ghost-bm">{bookmark}</span>
        {rest && <span className="zs-ghost-rest">{rest}</span>}
      </div>
    );
  } else if (kind === "diff") {
    chip = (
      <div className="zs-ghost-card is-diff">
        {status && <span className={"zs-file-status s-" + status}>{status}</span>}
        <span className={"zs-ghost-subj" + (status ? " is-mono" : "")}>{label}</span>
        <span className="zs-ghost-stat"><span className="a">+{added || 0}</span><span className="r">−{removed || 0}</span></span>
      </div>
    );
  } else {
    chip = (
      <div className="zs-ghost-card">
        {workingCopy && <AtBadge size="sm" />}
        <span className="zs-cid"><b>{id.slice(0, 2)}</b>{id.slice(2, 8)}</span>
        <span className="zs-ghost-subj">{subject || "(no description set)"}</span>
      </div>
    );
  }
  return (
    <div className={("zs-ghost " + className).trim()} style={style} aria-hidden="true">
      {chip}
      {(command || target || hint) && <div className={"zs-ghost-cmd" + (command ? " is-on" : target ? " is-on is-words" : "")}>{command || target ? <span>{command || target}</span> : <span className="zs-ghost-alt">{hint}</span>}</div>}
    </div>
  );
}
