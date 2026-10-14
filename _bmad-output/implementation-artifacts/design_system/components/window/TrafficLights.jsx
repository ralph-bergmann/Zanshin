import React from "react";

// TrafficLights — macOS window controls. They belong to the window, not the project: they sit alone in the 52px chrome column.
export function TrafficLights({ idle = false, onClose, onMinimize, onZoom }) {
  return (
    <div className={"zs-traffic" + (idle ? " is-idle" : "")}>
      <button type="button" className="c" aria-label="Close window" onClick={onClose}></button>
      <button type="button" className="m" aria-label="Minimize" onClick={onMinimize}></button>
      <button type="button" className="z" aria-label="Zoom" onClick={onZoom}></button>
    </div>
  );
}
