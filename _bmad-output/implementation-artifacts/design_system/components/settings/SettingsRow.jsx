import React from "react";

// SettingsRow — label (+ hint, + the jj config key it writes) left, control right. stack: the control goes full-width below (long revsets).
export function SettingsRow({ label, hint, configKey, stack = false, children, className = "" }) {
  return (
    <div className={["zs-setrow", stack && "is-stack", className].filter(Boolean).join(" ")}>
      <div className="zs-setrow-lbl">
        <span>{label}</span>
        {hint && <span className="zs-setrow-hint">{hint}</span>}
        {configKey && <code className="zs-setrow-cfg">{configKey}</code>}
      </div>
      <div className="zs-setrow-ctl">{children}</div>
    </div>
  );
}
