import * as React from "react";

/** Row of the Projects tree: a repository, or a group of them. States: rest · hover · pressed · selected (--accent-soft; pressed --accent-soft-hi) · focus-visible (inside) · open (OPEN) · missing · group expanded / collapsed · ••• on hover or focus · moving: dragging (in hand) · drop before / after / into / end · a group's name being typed (editing: new or rename). */
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
  /** show the ••• button on hover and with focus — projects and groups (default true) */
  more?: boolean;
  /** a group: its name as a field in place (TextField sm, focused, selected) — `name` empty = a new group, else Rename…. ↩ commits,
   *  Esc cancels; a click elsewhere cancels a new group and keeps a rename; an empty name cancels */
  editing?: boolean;
  /** editing: the name typed (trimmed, never empty) */
  onCommit?: (name: string) => void;
  /** editing: Esc, an empty name, or a click elsewhere on a new group */
  onCancel?: () => void;
  /** moving rows: the row in hand — stays in place at 40% */
  dragging?: boolean;
  /** where the row in hand would land: before / after this row (a 2px line at its indent) · into this group (soft fill, line border) ·
   *  end = below this row, the last one, at indent 0 (the end of the top level). Live accent: a drop target never goes neutral. */
  drop?: "before" | "after" | "into" | "end";
  onMore?: (e: React.MouseEvent) => void;
  /** a group: expand / collapse (→ ← ↩) */
  onToggle?: () => void;
  /** keyboard focus moved here (↑ ↓) — select it */
  onSelect?: () => void;
  /** roving tab stop — default: 0 when selected, else −1 */
  tabIndex?: number;
}
export declare function ProjectRow(props: ProjectRowProps): JSX.Element;
