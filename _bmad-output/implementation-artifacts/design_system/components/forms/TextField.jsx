import React from "react";

// TextField — the inset field: a darker well on glass (light: near-white), hairline, moon focus ring.
// size: sm 30px / 12.5px (settings) · md 34px / 13.5px semibold (composer summary) · lg 36px / 15px semibold (describe summary)
// multiline: the details textarea (13px / 1.5); size "md" makes it the compact composer version (44px, no resize).
export function TextField({ size = "sm", multiline = false, mono = false, rows = 2, inputRef, className = "", ...rest }) {
  const cls = ["zs-field", multiline ? "zs-field--area" : "zs-field--" + size, multiline && size === "md" && "is-compact", mono && "is-mono", className].filter(Boolean).join(" ");
  if (multiline) return <textarea ref={inputRef} className={cls} rows={rows} {...rest}></textarea>;
  return <input ref={inputRef} className={cls} {...rest} />;
}
