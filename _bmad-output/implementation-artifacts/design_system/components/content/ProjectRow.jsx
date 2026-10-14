import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Repository status → dot colour, exactly the client's STATUS_META.
export const zsProjectStatus = {
  clean: { color: "#9ca3af", label: "clean" },
  dirty: { color: "#facc15", label: "uncommitted changes" },
  ahead: { color: "#4ade80", label: "ahead of remote" },
  behind: { color: "#60a5fa", label: "behind remote" },
  diverged: { color: "#fb923c", label: "diverged" },
  conflict: { color: "#f87171", label: "conflict" },
  missing: { color: "#71717a", label: "path missing" },
  syncing: { color: "#a78bfa", label: "syncing" },
};

// ProjectRow — one row of the Projects tree. kind "project": status dot, name, OPEN (the repo in this window), branch, ↑↓, path · last opened, ••• on hover.
// kind "group": chevron, folder, CAPS name, count. depth indents 16px per level. Double-click (or ↩) opens a project.
export function ProjectRow({ kind = "project", name, path, branch, status = "clean", ahead, behind, lastOpened, open = false, selected = false, depth = 0,
  expanded = false, count, groups, more = true, onClick, onDoubleClick, onMore, className = "", ...rest }) {
  if (kind === "group") {
    return (
      <div role="treeitem" aria-expanded={expanded} className={["zs-proj is-group", selected && "is-sel", className].filter(Boolean).join(" ")} style={{ "--depth": depth }} onClick={onClick} {...rest}>
        <span className={"zs-proj-chev" + (expanded ? " is-open" : "")}><Icon name="chevron-right" size={12} /></span>
        <Icon name={expanded ? "folder-open" : "folder"} size={14} className="zs-proj-icon" />
        <span className="zs-proj-name">{name}</span>
        <span className="zs-proj-count">{count}{groups > 0 ? " · " + groups + (groups === 1 ? " group" : " groups") : ""}</span>
      </div>
    );
  }
  const s = zsProjectStatus[status] || zsProjectStatus.clean;
  return (
    <div role="treeitem" aria-selected={selected} className={["zs-proj", selected && "is-sel", open && "is-open", status === "missing" && "is-missing", className].filter(Boolean).join(" ")}
      style={{ "--depth": depth }} onClick={onClick} onDoubleClick={onDoubleClick} title={path} {...rest}>
      <span className="zs-proj-chev"></span>
      <span className="zs-proj-dot" style={{ background: s.color }} title={s.label}></span>
      <div className="zs-proj-text">
        <div className="zs-proj-l1">
          <span className="zs-proj-name">{name}</span>
          {open && <span className="zs-proj-open">open</span>}
          {branch && branch !== "—" && <span className="zs-proj-branch"><Icon name="branch" size={10} />{branch}</span>}
          {ahead > 0 && <span className="zs-proj-meta is-ahead">↑{ahead}</span>}
          {behind > 0 && <span className="zs-proj-meta is-behind">↓{behind}</span>}
        </div>
        {(path || lastOpened) && (
          <div className="zs-proj-l2">
            {path && <span className="zs-proj-path">{path}</span>}
            {path && lastOpened && <span className="zs-proj-sep">·</span>}
            {lastOpened && <span className="zs-proj-when">{lastOpened}</span>}
          </div>
        )}
      </div>
      {more && <button type="button" className="zs-proj-more" title="More…" aria-label="More" onClick={(e) => { e.stopPropagation(); onMore && onMore(e); }}><Icon name="more" size={13} /></button>}
    </div>
  );
}
