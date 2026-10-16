import React from "react";
import { Menu } from "./Menu.jsx";
import { zsProjectStatus } from "../content/ProjectRow.jsx";

// ProjectMenu — drops from the project capsule. It IS a Menu (one highlight, ↑↓ Home End, typeahead on the project name, blink,
// closing exit): Recent (✓ = open, status dot, branch in the mono column) · All Projects… ⇧⌘O · Project Settings… (the Project tab) · Settings… ⌘, (does exactly what ⌘, does: the tab shown last)
// recent: [{ id, name, branch, status, path }] — status keys as in ProjectRow (clean, dirty, ahead, behind, diverged, conflict, syncing)
export function ProjectMenu({ recent = [], activeId, onPick, onAll, onProjectSettings, onSettings, closing = false, autoFocus = false, onClose, className = "", style }) {
  const items = [
    { header: "Recent" },
    ...recent.map((p) => {
      const s = zsProjectStatus[p.status] || zsProjectStatus.clean;
      return {
        id: "p:" + p.id, text: p.name, title: p.path, checked: p.id === activeId, radio: true, cmd: p.branch,
        label: <span className="zs-pm-l"><span className="zs-pm-name">{p.name}</span><span className="zs-pm-dot" style={{ background: s.color }} title={s.label}></span></span>,
      };
    }),
    "sep",
    { id: "all", label: "All Projects…", shortcut: "⇧⌘O" },
    "sep",
    { id: "project-settings", label: "Project Settings…", disabled: !activeId },
    { id: "settings", label: "Settings…", shortcut: "⌘," },
  ];
  const pick = (id) => {
    if (id === "all") onAll && onAll();
    else if (id === "project-settings") onProjectSettings && onProjectSettings();
    else if (id === "settings") onSettings && onSettings();
    else { const p = recent.find((r) => "p:" + r.id === id); p && onPick && onPick(p); }
  };
  return <Menu aria-label="Project" items={items} onSelect={pick} onClose={onClose} autoFocus={autoFocus} closing={closing} className={("zs-pm " + className).trim()} style={style} />;
}
