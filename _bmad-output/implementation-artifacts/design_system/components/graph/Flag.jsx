import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Flag — status pill in the inspector header. kind: neutral (Immutable, Empty, Merge) · wc (Working copy) · warn (Conflict)
// icon: an Icon name or a node — Immutable carries the HatchSwatch (no ◆), its title the reason ("Immutable · below trunk() · main").
export function Flag({ kind = "neutral", icon, title, children }) {
  return (
    <span className={"zs-flag" + (kind !== "neutral" ? " is-" + kind : "")} title={title}>
      {icon && (typeof icon === "string" ? <Icon name={icon} size="sm" /> : icon)}
      {children}
    </span>
  );
}
