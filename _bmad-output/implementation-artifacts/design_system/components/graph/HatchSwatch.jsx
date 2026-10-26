import React from "react";

// HatchSwatch — the key to the immutable look: a 12px card in miniature (radius 3, 1px --border-strong, --card-solid) with a denser hatch
// (1px every 3px in --hatch-mark). It stands wherever "immutable" is named — the peek's eyebrow, the card menu's note row, the inspector's
// flag, the Immutable commits row and page — in the icon column. Immutable has no colour and no ◆: the hatch is the marker, the swatch names it.
export function HatchSwatch({ title, className = "", style }) {
  return <span className={("zs-hatch " + className).trim()} style={style} title={title} role={title ? "img" : undefined} aria-label={title} aria-hidden={title ? undefined : true}></span>;
}
