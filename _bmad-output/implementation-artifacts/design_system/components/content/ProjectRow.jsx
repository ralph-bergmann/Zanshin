import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { TextField } from "../forms/TextField.jsx";

// Repository status → dot colour, exactly the client's STATUS_META.
export const zsProjectStatus = {
  clean: { color: "var(--proj-clean)", label: "clean" },
  dirty: { color: "var(--proj-dirty)", label: "uncommitted changes" },
  ahead: { color: "var(--proj-ahead)", label: "ahead of remote" },
  behind: { color: "var(--proj-behind)", label: "behind remote" },
  diverged: { color: "var(--proj-diverged)", label: "diverged" },
  conflict: { color: "var(--proj-conflict)", label: "conflict" },
  missing: { color: "var(--proj-missing)", label: "path missing" },
  syncing: { color: "var(--proj-syncing)", label: "syncing" },
  stale: { color: "var(--proj-stale)", label: "working copy is stale" },
};

// ProjectRow — one row of the Projects tree. kind "project": status dot, name, OPEN (the repo in this window), branch, ↑↓, path · last opened, ••• on hover.
// kind "group": chevron, folder, CAPS name, count. depth indents 16px per level. Double-click (or ↩) opens a project.
// Keyboard (a tree, one Tab stop — the selected row): ↑ ↓ move and select · Home End · → expands a group, or steps into it ·
// ← collapses, or steps to the parent · ↩ opens a project (a group: toggles) · ••• is reachable with Tab from its row and shows with focus.
// VoiceOver: tree item with level, expanded / collapsed, selected; the status dot reads as its label (clean, ahead …).
// Moving rows: dragging = the row in hand (stays in place, faded) · drop = where it would land: before / after this row (a line at its
// indent) · into this group (fill + border) · end (below this last row, at indent 0 — the end of the top level).
// editing (a group): its name as a field in place — a new group (no name yet) or Rename…. ↩ commits, Esc cancels; a click elsewhere
// cancels a new group and keeps a rename; an empty name cancels. ••• (onMore) opens the row's menu, on projects and groups alike.
function zsTreeKeys(e, { group, expanded, depth, onToggle, onOpen }) {
  if (e.target !== e.currentTarget) return;
  const tree = e.currentTarget.closest('[role="tree"]');
  const items = tree ? [...tree.querySelectorAll('[role="treeitem"]')] : [e.currentTarget];
  const i = items.indexOf(e.currentTarget);
  const go = (j) => { const el = items[Math.max(0, Math.min(items.length - 1, j))]; if (el) { e.preventDefault(); el.focus(); } };
  if (e.key === "ArrowDown") go(i + 1);
  else if (e.key === "ArrowUp") go(i - 1);
  else if (e.key === "Home") go(0);
  else if (e.key === "End") go(items.length - 1);
  else if (e.key === "ArrowRight" && group) { e.preventDefault(); if (!expanded) onToggle && onToggle(); else go(i + 1); }
  else if (e.key === "ArrowLeft") {
    e.preventDefault();
    if (group && expanded) { onToggle && onToggle(); return; }
    for (let j = i - 1; j >= 0; j--) if (Number(items[j].getAttribute("aria-level")) < depth + 1) { items[j].focus(); return; }
  } else if (e.key === "Enter") { e.preventDefault(); if (group) onToggle && onToggle(); else onOpen && onOpen(); }
}
export function ProjectRow({ kind = "project", name, path, branch, status = "clean", ahead, behind, lastOpened, open = false, selected = false, depth = 0,
  expanded = false, count, groups, more = true, dragging = false, drop, editing = false, onCommit, onCancel, onClick, onDoubleClick, onMore, onToggle, onSelect, tabIndex, className = "", ...rest }) {
  const moving = [dragging && "is-dragging", drop && "is-drop-" + drop];
  const focus = (e) => { try { if (e.target === e.currentTarget && e.currentTarget.matches(":focus-visible")) onSelect && onSelect(); } catch (_) {} };
  const moreButton = more && <button type="button" className="zs-proj-more" title="More…" aria-label="More" aria-haspopup="menu" onClick={(e) => { e.stopPropagation(); onMore && onMore(e); }}><Icon name="more" size="md" /></button>;
  if (kind === "group" && editing) {
    const fresh = !name;
    // ↩ / Esc decide; the blur of the field going away must not decide again
    const decide = (el, keep) => { el.dataset.done = "1"; const v = el.value.trim(); if (keep && v) onCommit && onCommit(v); else onCancel && onCancel(); };
    return (
      <div role="treeitem" aria-level={depth + 1} className={["zs-proj is-group is-editing", className].filter(Boolean).join(" ")} style={{ "--depth": depth }} {...rest}>
        <span className="zs-proj-chev"></span>
        <Icon name="folder" size="md" className="zs-proj-icon" />
        <TextField size="sm" className="zs-proj-field" defaultValue={name} placeholder="Group name" aria-label={fresh ? "New group" : "Rename group"}
          inputRef={(el) => { if (el && !el.dataset.ready) { el.dataset.ready = "1"; el.focus(); el.select(); } }}
          onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter" || e.key === "Escape") { e.preventDefault(); decide(e.currentTarget, e.key === "Enter"); } }}
          onBlur={(e) => { if (!e.target.dataset.done) decide(e.target, !fresh); }} />
      </div>
    );
  }
  if (kind === "group") {
    return (
      <div role="treeitem" aria-expanded={expanded} aria-level={depth + 1} aria-selected={selected} tabIndex={tabIndex != null ? tabIndex : selected ? 0 : -1}
        className={["zs-proj is-group", selected && "is-sel", ...moving, className].filter(Boolean).join(" ")} style={{ "--depth": depth }} onClick={onClick} onFocus={focus}
        onKeyDown={(e) => zsTreeKeys(e, { group: true, expanded, depth, onToggle: onToggle || onClick })} {...rest}>
        <span className={"zs-proj-chev" + (expanded ? " is-open" : "")}><Icon name="chevron-right" size="sm" /></span>
        <Icon name={expanded ? "folder-open" : "folder"} size="md" className="zs-proj-icon" />
        <span className="zs-proj-name">{name}</span>
        <span className="zs-proj-count">{count}{groups > 0 ? " · " + groups + (groups === 1 ? " group" : " groups") : ""}</span>
        {moreButton}
      </div>
    );
  }
  const s = zsProjectStatus[status] || zsProjectStatus.clean;
  return (
    <div role="treeitem" aria-selected={selected} aria-level={depth + 1} tabIndex={tabIndex != null ? tabIndex : selected ? 0 : -1}
      className={["zs-proj", selected && "is-sel", open && "is-open", status === "missing" && "is-missing", ...moving, className].filter(Boolean).join(" ")}
      style={{ "--depth": depth }} onClick={onClick} onDoubleClick={onDoubleClick} onFocus={focus} title={path}
      onKeyDown={(e) => zsTreeKeys(e, { group: false, depth, onOpen: onDoubleClick })} {...rest}>
      <span className="zs-proj-chev"></span>
      <span className="zs-proj-dot" style={{ background: s.color }} title={s.label}></span>
      <div className="zs-proj-text">
        <div className="zs-proj-l1">
          <span className="zs-proj-name">{name}</span>
          {open && <span className="zs-proj-open">open</span>}
          {branch && branch !== "—" && <span className="zs-proj-branch"><Icon name="branch" size="xs" />{branch}</span>}
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
      {moreButton}
    </div>
  );
}
