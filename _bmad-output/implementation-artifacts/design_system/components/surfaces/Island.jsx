import React from "react";

// Island — the floating glass container. The graph owns the window; every control floats above it in one of these.
// shape: bar (44px, top bar) · rail (vertical icon column) · panel (inspector / pinned panel, stronger glass) · free (no preset geometry)
export function Island({ shape = "bar", as = "div", className = "", children, ...rest }) {
  const Tag = as;
  return (
    <Tag className={["zs-island zs-glass", shape !== "free" && "zs-island--" + shape, className].filter(Boolean).join(" ")} {...rest}>
      {children}
    </Tag>
  );
}

export function IslandSeparator() {
  return <span className="zs-island-sep" aria-hidden="true"></span>;
}
