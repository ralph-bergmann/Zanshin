import React from "react";
import { TrafficLights } from "./TrafficLights.jsx";

// Window — a macOS window of its own (Settings, Projects, jj log Configurations): closable, not minimisable, above the project window even in full screen.
// The system draws corners, shadow and the open / close animation; Zanshin draws the content on --fl-sheen over --fl-bg-solid.
// title: the window title — in the Window menu and Mission Control even when the header doesn't show it (titleHidden: Settings).
// header: controls in the 52px header row, after the title (or centred with headerAlign "center"). Empty header space drags the window.
// sidebar: a column that begins under the traffic lights (Projects); the header then runs over the main column only.
// active false = not the key window: the accent role goes neutral and nothing shows focus (tokens/inactive.css).
export function Window({ title, titleHidden = false, active = true, buttons = { close: true }, header, headerAlign = "start", sidebar, sidebarWidth = 220,
  width, height, onClose, onZoom, className = "", style, children }) {
  const lights = <TrafficLights buttons={buttons} onClose={onClose} onZoom={onZoom} />;
  const hd = (
    <header className={"zs-win-hd" + (headerAlign === "center" ? " is-center" : "")} data-drag="window">
      {!sidebar && lights}
      {!titleHidden && <h1 className="zs-win-title">{title}</h1>}
      {header}
    </header>
  );
  const cls = ["zs-win", !active && "is-inactive", sidebar && "has-side", className].filter(Boolean).join(" ");
  return (
    <div className={cls} role="dialog" aria-label={title} data-window={active ? undefined : "inactive"} style={{ width, height, ...style }}>
      {sidebar ? <>
        {lights}
        <aside className="zs-win-side" style={{ width: sidebarWidth }}>{sidebar}</aside>
        <div className="zs-win-col">{hd}<div className="zs-win-main">{children}</div></div>
      </> : <>
        {hd}
        <div className="zs-win-bd"><div className="zs-win-main">{children}</div></div>
      </>}
    </div>
  );
}
