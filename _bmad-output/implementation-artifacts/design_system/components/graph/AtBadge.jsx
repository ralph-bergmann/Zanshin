import React from "react";

// AtBadge — "@", the working copy. Saffron is reserved for it: nothing else in the UI may use --co.
export function AtBadge({ size = "md" }) {
  return <span className={"zs-at" + (size === "sm" ? " is-sm" : "")} title="Working copy (@)">@</span>;
}
