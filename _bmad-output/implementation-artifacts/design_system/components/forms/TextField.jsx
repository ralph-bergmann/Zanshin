import React from "react";
import { Icon } from "../brand/Icon.jsx";

// TextField — the inset field: a darker well on glass (light: near-white), hairline, moon focus border + halo.
// size: sm 30 / 12.5px (settings) · md 36 / 13px semibold (composer summary) · lg 36 / 15px semibold (describe summary) — --control-md / --control-lg
// multiline: the details textarea (13px / 1.5); size "md" makes it the compact composer version (44px, no resize).
// error: true or the message (red edge + halo, message line below) · message: a neutral hint line · readOnly: dashed edge, selectable.
export function TextField({ size = "sm", multiline = false, mono = false, rows = 2, inputRef, error, message, className = "", style, ...rest }) {
  const id = React.useId();
  const msg = typeof error === "string" ? error : message;
  const cls = ["zs-field", multiline ? "zs-field--area" : "zs-field--" + size, multiline && size === "md" && "is-compact", mono && "is-mono", className].filter(Boolean).join(" ");
  const a = { className: cls, "aria-invalid": error ? true : undefined, "aria-describedby": msg ? id : undefined, ...rest };
  const field = multiline ? <textarea ref={inputRef} rows={rows} style={msg ? undefined : style} {...a}></textarea> : <input ref={inputRef} style={msg ? undefined : style} {...a} />;
  if (!msg) return field;
  return (
    <span className="zs-fieldwrap" style={style}>
      {field}
      <span id={id} className={"zs-field-msg" + (error ? " is-error" : "")} role={error ? "alert" : undefined}>
        {error && <Icon name="alert" size={12} />}{msg}
      </span>
    </span>
  );
}
