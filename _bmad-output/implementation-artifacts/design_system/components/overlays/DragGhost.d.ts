import * as React from "react";

/** The chip under the pointer while dragging a change, bookmark, file or hunk — plus the command a drop would run. */
export interface DragGhostProps {
  kind?: "change" | "bookmark" | "diff";
  /** change: id, subject, workingCopy */
  id?: string;
  subject?: string;
  workingCopy?: boolean;
  /** bookmark: the leading part (ticket id or last segment) and the rest */
  bookmark?: string;
  rest?: string;
  /** diff: file status (omit for multi-file), label ("swipe_controller.dart", "2 hunks of …"), counts */
  status?: "M" | "A" | "D" | null;
  label?: string;
  added?: number;
  removed?: number;
  /** the jj command of the default drop action → moon border */
  command?: string;
  /** shown while no target is under the pointer: "Drop on a change" */
  hint?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function DragGhost(props: DragGhostProps): JSX.Element;
