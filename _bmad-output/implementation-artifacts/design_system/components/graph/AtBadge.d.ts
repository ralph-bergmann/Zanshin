import * as React from "react";

/** "@" working-copy badge — this workspace's, saffron. With two or more workspaces it reads name@ (as jj log). States: none — md / sm, named. */
export interface AtBadgeProps { size?: "md" | "sm"; /** this workspace's name — only when the repo has two or more workspaces */ name?: string; }
export declare function AtBadge(props: AtBadgeProps): JSX.Element;
/** Another workspace's working copy on this commit: name@, quiet (--text-muted, 1px --border-strong), never saffron. more = "+N" (title lists the rest). States: none. */
export declare function WorkspaceTag(props: { name?: string; more?: number; title?: string }): JSX.Element;
