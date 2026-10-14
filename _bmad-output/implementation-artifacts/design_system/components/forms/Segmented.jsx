import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Segmented — 2–4 mutually exclusive options. options: ["A","B"] or [{ value, label, icon, title }]
// variant: default (view menu, 22px) · tabs (settings window scope tabs, 28px) · inset (inside a settings row, darker track, 24px)
// size sm: icon-only toggles in a diff toolbar (18px)
export function Segmented({ options = [], value, onChange, label, variant = "default", size = "md", role = "radiogroup" }) {
  const tabs = variant === "tabs";
  const cls = ["zs-seg", variant !== "default" && "zs-seg--" + variant, size === "sm" && "zs-seg--sm"].filter(Boolean).join(" ");
  return (
    <div className={cls} role={tabs ? "tablist" : role} aria-label={label}>
      {options.map((o) => {
        const v = typeof o === "string" ? o : o.value;
        const l = typeof o === "string" ? o : o.label;
        const on = v === value;
        return (
          <button key={v} type="button" role={tabs ? "tab" : "radio"} aria-checked={tabs ? undefined : on} aria-selected={tabs ? on : undefined}
            aria-label={!l && o.title ? o.title : undefined} className={"zs-seg-btn" + (on ? " is-on" : "")} title={o.title} onClick={() => onChange && onChange(v)}>
            {o.icon && (typeof o.icon === "string" ? <Icon name={o.icon} size={size === "sm" ? 12 : tabs ? 13 : 12} /> : o.icon)}
            {l}
          </button>
        );
      })}
    </div>
  );
}
