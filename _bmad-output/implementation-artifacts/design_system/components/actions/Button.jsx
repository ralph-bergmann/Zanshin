import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Button — sm 30px (inspector), md 32px (dialogs), lg 44px (the bar's one primary action).
// variant: default (quiet fill) · primary (gold, once per view) · ghost · danger (quiet until hover)
export function Button({ variant = "default", size = "sm", icon, iconSize, children, className = "", type = "button", ...rest }) {
  const cls = ["zs-btn", variant !== "default" && "zs-btn--" + variant, size !== "sm" && "zs-btn--" + size, className].filter(Boolean).join(" ");
  const isz = iconSize || (size === "lg" ? 15 : 13);
  return (
    <button type={type} className={cls} {...rest}>
      {typeof icon === "string" ? <Icon name={icon} size={isz} /> : icon}
      {children != null && <span>{children}</span>}
    </button>
  );
}
