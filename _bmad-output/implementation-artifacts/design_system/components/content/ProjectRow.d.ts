import * as React from "react";

/** Row of the Projects tree: a repository, or a group of them. States: rest · hover · pressed · selected (--accent-soft; pressed --accent-soft-hi) · focus-visible (inside) · open (OPEN) · missing · group expanded / collapsed · ••• on hover or focus. */
export interface ProjectRowProps extends React.HTMLAttributes<HTMLDivElement> {
  kind?: "project" | "group";
  name: string;
  path?: string;
  /** current bookmark/branch shown next to the name ("—" hides it) */
  branch?: string;
  /** dot colour: clean · dirty · ahead · behind · diverged · conflict · missing · syncing */
  status?: "clean" | "dirty" | "ahead" | "behind" | "diverged" | "conflict" | "missing" | "syncing" | "stale";
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
  /** a group: expand / collapse (→ ← ↩) */
  onToggle?: () => void;
  /** keyboard focus moved here (↑ ↓) — select it */
  onSelect?: () => void;
  /** roving tab stop — default: 0 when selected, else −1 */
  tabIndex?: number;
}
export declare function ProjectRow(props: ProjectRowProps): JSX.Element;
