import React from "react";

// ChangeId — jj change id; the unique prefix is bold (2 characters by default; search rows bold the typed prefix).
// Immutable history has no mark here — the card's hatch carries it (the ◆ is retired).
export function ChangeId({ id = "", length = 5, prefix = 2 }) {
  return (
    <span className="zs-cid">
      <b>{id.slice(0, prefix)}</b>
      {id.slice(prefix, length)}
    </span>
  );
}
