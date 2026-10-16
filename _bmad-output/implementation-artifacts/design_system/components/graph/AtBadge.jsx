import React from "react";

// AtBadge — "@", the working copy of THIS workspace. Saffron is reserved for it: nothing else in the UI may use --co.
// name: with two or more workspaces jj prints every working copy as name@ (ours included: default@) — so does the badge.
// With one workspace jj prints no marker, and the badge stays a plain "@".
export function AtBadge({ size = "md", name }) {
  return (
    <span className={"zs-at" + (size === "sm" ? " is-sm" : "") + (name ? " is-named" : "")} title={name ? "Working copy of " + name + " — this workspace" : "Working copy (@)"}>
      {name && <span className="zs-at-n">{name}</span>}@
    </span>
  );
}

// WorkspaceTag — another workspace's working copy on this commit (name@): quiet, never saffron — gold is only ours.
export function WorkspaceTag({ name, more, title }) {
  return <span className={"zs-ws" + (more ? " is-more" : "")} title={title || (more ? undefined : "Working copy of the workspace " + name)}>{more ? "+" + more : <><span className="zs-ws-n">{name}</span>@</>}</span>;
}
