import React from "react";

// Popover — settings sheet dropped from an island (View options). Caps headers, 36px option rows, hairline separators.
export function Popover({ width = 340, className = "", style, children, ...rest }) {
  return (
    <div role="dialog" className={("zs-popover " + className).trim()} style={{ width, ...style }} {...rest}>
      {children}
    </div>
  );
}

export function PopoverHeader({ children }) {
  return <div className="zs-popover-h">{children}</div>;
}

export function PopoverSeparator() {
  return <div className="zs-popover-sep" role="separator"></div>;
}

// OptionRow — label left, control right (Segmented, Switch, Slider).
export function OptionRow({ label, title, children }) {
  return (
    <div className="zs-option" title={title}>
      <span>{label}</span>
      {children}
    </div>
  );
}

// OptionLink — a row that leaves the popover for a bigger place: "Appearance, diffs and more" · "Settings… ⌘,"
export function OptionLink({ label, action, shortcut, onClick }) {
  return (
    <button type="button" className="zs-option-link" onClick={onClick}>
      <span>{label}</span>
      {(action || shortcut) && <span className="zs-option-k">{action}{shortcut && <kbd>{shortcut}</kbd>}</span>}
    </button>
  );
}
