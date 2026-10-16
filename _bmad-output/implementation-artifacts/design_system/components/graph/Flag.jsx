import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Flag — status pill in the inspector header. kind: neutral (Immutable, Empty, Merge) · wc (Working copy) · warn (Conflict)
export function Flag({ kind = "neutral", icon, title, children }) {
  return (
    <span className={"zs-flag" + (kind !== "neutral" ? " is-" + kind : "")} title={title}>
      {icon && <Icon name={icon} size="sm" />}
      {children}
    </span>
  );
}
