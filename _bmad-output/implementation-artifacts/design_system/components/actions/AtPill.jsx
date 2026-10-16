import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { AtBadge } from "../graph/AtBadge.jsx";

// AtPill — the "@ Working copy" locator. Render it only while @ is out of view.
// It carries an ARROW, not a chevron: an arrow means "it is over there", a chevron would mean "this opens".
export function AtPill({ direction = "down", label = "Working copy", className = "", ...rest }) {
  return (
    <button type="button" className={("zs-atpill dir-" + direction + " " + className).trim()} title="Scroll to the working copy" {...rest}>
      <AtBadge />
      <span>{label}</span>
      <Icon name="arrow-up" size="md" />
    </button>
  );
}
