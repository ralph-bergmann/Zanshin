import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Callout — hover preview for a rail button; the arrow points at the button it belongs to.
export function Callout({ icon, title, count, arrow = true, className = "", style, children }) {
  return (
    <div role="tooltip" className={["zs-callout", !arrow && "no-arrow", className].filter(Boolean).join(" ")} style={style}>
      {title && (
        <div className="zs-callout-hd">
          {icon && <Icon name={icon} size="md" />}
          <span>{title}</span>
          {count != null && <span className="zs-callout-n">{count}</span>}
        </div>
      )}
      <div className="zs-callout-bd">{children}</div>
    </div>
  );
}

// CalloutText — the quiet one-liner for empty states ("No open reviews.").
export function CalloutText({ children }) {
  return <div className="zs-callout-text">{children}</div>;
}
