import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Spinner } from "../controls/Spinner.jsx";

// Button — 30px (--control-md: inspector, dialogs, settings — sm and md are one height) · lg 44px (--control-xl: the bar's one primary action).
// variant: default (quiet fill) · primary (gold, once per view) · ghost · danger (quiet until hover) · destructive (filled red — a confirmation's one primary)
// busy: a spinner takes the icon slot, the label stays, clicks are ignored. No children = icon-only (square); pass label for VoiceOver.
export function Button({ variant = "default", size = "sm", icon, iconSize, busy = false, label, children, className = "", type = "button", ...rest }) {
  const iconOnly = children == null && icon != null;
  const cls = ["zs-btn", variant !== "default" && "zs-btn--" + variant, size !== "sm" && "zs-btn--" + size, iconOnly && "zs-btn--icon", className].filter(Boolean).join(" ");
  const isz = iconSize || (size === "lg" ? "lg" : "md");
  return (
    <button type={type} className={cls} aria-busy={busy || undefined} aria-label={iconOnly ? label : undefined} title={iconOnly && rest.title === undefined ? label : rest.title} {...rest}>
      {busy ? <Spinner size={typeof isz === "string" ? Icon.sizes[isz] : isz} /> : typeof icon === "string" ? <Icon name={icon} size={isz} /> : icon}
      {children != null && <span>{children}</span>}
    </button>
  );
}
