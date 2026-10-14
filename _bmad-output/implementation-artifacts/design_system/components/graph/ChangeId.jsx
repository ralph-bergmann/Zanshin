import React from "react";

// ChangeId — jj change id; the unique prefix is bold (2 characters by default; search rows bold the typed prefix). ◆ marks immutable history.
export function ChangeId({ id = "", length = 5, prefix = 2, immutable = false }) {
  return (
    <span className="zs-cid">
      {immutable && <span className="zs-cid-imm" title="immutable">◆</span>}
      <b>{id.slice(0, prefix)}</b>
      {id.slice(prefix, length)}
    </span>
  );
}
