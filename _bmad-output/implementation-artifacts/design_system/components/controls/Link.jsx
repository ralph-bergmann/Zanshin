import React from "react";

// Link — two kinds only. inline (prose, accent text, underline on hover) · quiet (footers and utilities: dim → text, never underlined).
// With href it is an <a> (the one place the pointing hand is allowed); without, a button styled as a link (arrow cursor).
export function Link({ href, quiet = false, external = false, children, className = "", ...rest }) {
  const cls = ["zs-link", quiet && "zs-link--quiet", className].filter(Boolean).join(" ");
  if (href) return <a className={cls} href={href} target={external ? "_blank" : undefined} rel={external ? "noreferrer" : undefined} {...rest}>{children}{external && <span aria-hidden="true"> ↗</span>}</a>;
  return <button type="button" className={cls} {...rest}>{children}</button>;
}
