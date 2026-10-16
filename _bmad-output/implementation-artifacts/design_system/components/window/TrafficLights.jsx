import React from "react";

// TrafficLights — a mock of the system's window buttons (cards, the UI kit); in the app AppKit draws them where macOS puts them.
// At rest: grey rings (Zanshin's TrafficLightOverlayView — the one deviation from the system, on purpose). Hovering the group shows
// the system's buttons: enabled ones in colour with their symbols, disabled ones greyed. 14 × 14, pitch 23 (macOS 26 and later).
// buttons — which are enabled: the project window all three · Projects { close, zoom } · Settings { close }.
export function TrafficLights({ buttons = { close: true, minimize: true, zoom: true }, hover = false, onClose, onMinimize, onZoom, className = "", style }) {
  return (
    <div className={["zs-traffic", hover && "is-hover", className].filter(Boolean).join(" ")} style={style} role="group" aria-label="Window">
      <button type="button" className="c" aria-label="Close" disabled={!buttons.close} onClick={onClose}></button>
      <button type="button" className="m" aria-label="Minimize" disabled={!buttons.minimize} onClick={onMinimize}></button>
      <button type="button" className="z" aria-label="Zoom" disabled={!buttons.zoom} onClick={onZoom}></button>
    </div>
  );
}
