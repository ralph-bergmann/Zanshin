import React from "react";
import { Icon } from "../brand/Icon.jsx";

// IconButton — sm 28 (panel close) · md 36 (inside islands) · lg 40 (rail). `active` = pressed/open state.
export function IconButton({ icon, label, size = "md", active = false, iconSize, className = "", type = "button", title, ...rest }) {
  const isz = iconSize || (size === "sm" ? 14 : size === "lg" ? 18 : 17);
  const cls = ["zs-ib", size !== "md" && "zs-ib--" + size, active && "is-on", className].filter(Boolean).join(" ");
  return (
    <button type={type} className={cls} aria-label={label} title={title === undefined ? label : title} {...rest}>
      {typeof icon === "string" ? <Icon name={icon} size={isz} /> : icon}
    </button>
  );
}
