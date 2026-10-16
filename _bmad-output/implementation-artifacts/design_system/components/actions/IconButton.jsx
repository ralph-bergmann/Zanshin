import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Badge } from "../controls/Badge.jsx";

// IconButton — sm 30 (--control-md: panel close) · md 36 (--control-lg: inside islands) · lg 40 (rail). Icons: sm 12 · bar 17 · rail 19. `active` = toggled/open. `badge` = a count on the corner (e.g. Fetch: incoming changes).
export function IconButton({ icon, label, size = "md", active = false, badge, iconSize, className = "", type = "button", title, ...rest }) {
  const isz = iconSize || (size === "sm" ? "sm" : size === "lg" ? "rail" : "bar");
  const cls = ["zs-ib", size !== "md" && "zs-ib--" + size, active && "is-on", className].filter(Boolean).join(" ");
  const hasBadge = badge != null && badge !== false && badge !== 0;
  return (
    <button type={type} className={cls} aria-label={hasBadge ? label + ", " + badge : label} aria-pressed={active || undefined} title={title === undefined ? label : title} {...rest}>
      {typeof icon === "string" ? <Icon name={icon} size={isz} /> : icon}
      {badge != null && badge !== false && <Badge count={badge} />}
    </button>
  );
}
