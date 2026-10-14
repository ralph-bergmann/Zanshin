import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { zsProjectStatus } from "../content/ProjectRow.jsx";

// ProjectMenu — drops from the project capsule: recent projects (✓ = open), All Projects…, Project Settings…, Settings… ⌘,
// recent: [{ id, name, branch, status }] — status keys as in ProjectRow (clean, dirty, ahead, behind, diverged, conflict, syncing)
export function ProjectMenu({ recent = [], activeId, onPick, onAll, onProjectSettings, onSettings, className = "", style }) {
  return (
    <div role="menu" aria-label="Project" className={("zs-pm " + className).trim()} style={style}>
      <div className="zs-pm-h">Recent</div>
      {recent.map((p) => {
        const s = zsProjectStatus[p.status] || zsProjectStatus.clean;
        const on = p.id === activeId;
        return (
          <button key={p.id} type="button" role="menuitemradio" aria-checked={on} className={"zs-pm-item" + (on ? " is-on" : "")} onClick={() => onPick && onPick(p)} title={p.path}>
            <span className="zs-pm-chk">{on && <Icon name="check" size={12} />}</span>
            <span className="zs-pm-name">{p.name}</span>
            <span className="zs-pm-dot" style={{ background: s.color }} title={s.label}></span>
            <span className="zs-pm-sub">{p.branch}</span>
          </button>
        );
      })}
      <div className="zs-pm-sep" role="separator"></div>
      <button type="button" role="menuitem" className="zs-pm-item" onClick={onAll}><span className="zs-pm-chk"></span><span className="zs-pm-name">All Projects…</span></button>
      <div className="zs-pm-sep" role="separator"></div>
      <button type="button" role="menuitem" className="zs-pm-item" onClick={onProjectSettings}><span className="zs-pm-chk"></span><span className="zs-pm-name">Project Settings…</span></button>
      <button type="button" role="menuitem" className="zs-pm-item" onClick={onSettings}><span className="zs-pm-chk"></span><span className="zs-pm-name">Settings…</span><kbd className="zs-pm-kbd">⌘,</kbd></button>
    </div>
  );
}
