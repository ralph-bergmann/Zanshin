import * as React from "react";

/** The chip under the pointer while dragging a change, bookmark, file or hunk — plus the command a drop would run — or a row of the Projects tree, plus where it goes. States: dragging · over a target (its command or target, accent edge) · over the drop menu (muted). */
export interface DragGhostProps {
  kind?: "change" | "bookmark" | "diff" | "project" | "group";
  /** change: id, subject, workingCopy */
  id?: string;
  subject?: string;
  workingCopy?: boolean;
  /** bookmark: the leading part (ticket id or last segment) and the rest */
  bookmark?: string;
  rest?: string;
  /** diff: file status (omit for multi-file), label ("swipe_controller.dart", "2 hunks of …"), counts ·
   *  project: the status key of its dot (as ProjectRow) and its name as label · group: its name as label */
  status?: "M" | "A" | "D" | null | "clean" | "dirty" | "ahead" | "behind" | "diverged" | "conflict" | "missing" | "syncing" | "stale";
  label?: string;
  added?: number;
  removed?: number;
  /** the jj command of the default drop action → moon border */
  command?: string;
  /** a list move (project / group): where it goes, in words — "Into Backend", "To the top level" → moon border, sans */
  target?: string;
  /** shown while no target is under the pointer: "Drop on a change" */
  hint?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function DragGhost(props: DragGhostProps): JSX.Element;
