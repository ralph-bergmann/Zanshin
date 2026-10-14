import * as React from "react";

/** Row of the Projects tree: a repository, or a group of them. */
export interface ProjectRowProps extends React.HTMLAttributes<HTMLDivElement> {
  kind?: "project" | "group";
  name: string;
  path?: string;
  /** current bookmark/branch shown next to the name ("—" hides it) */
  branch?: string;
  /** dot colour: clean · dirty · ahead · behind · diverged · conflict · missing · syncing */
  status?: "clean" | "dirty" | "ahead" | "behind" | "diverged" | "conflict" | "missing" | "syncing";
  ahead?: number;
  behind?: number;
  /** "now", "2d ago", "yesterday" */
  lastOpened?: string;
  /** the repository open in this window — saffron OPEN marker */
  open?: boolean;
  selected?: boolean;
  /** tree depth, 16px indent per level */
  depth?: number;
  /** group only */
  expanded?: boolean;
  /** group only: number of projects / sub-groups */
  count?: number;
  groups?: number;
  /** show the ••• button on hover (default true) */
  more?: boolean;
  onMore?: (e: React.MouseEvent) => void;
}
export declare function ProjectRow(props: ProjectRowProps): JSX.Element;
