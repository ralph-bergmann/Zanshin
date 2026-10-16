import * as React from "react";

/** One hunk of a file's diff, selectable for commit / split and draggable onto another change. States: rest · selected (header --accent-soft-hi, 2px accent edge on every line) · focus-visible (inside) · grab (grip on hover) · lifted (.38, dashed). */
export interface DiffHunkProps {
  /** header text; default built from oldStart/newStart: "@@ −12,6 +12,9 @@" */
  range?: string;
  oldStart?: number;
  newStart?: number;
  /** enclosing scope, e.g. "class SwipeController" */
  context?: string;
  /** lines with git sigils ("+…", "-…", " …") or { t, s } objects */
  lines: Array<string | { t: "add" | "rem" | "ctx"; s: string }>;
  mode?: "unified" | "split";
  /** show the selection checkbox (mutable changes) */
  selectable?: boolean;
  selected?: boolean;
  /** being dragged onto another change */
  lifted?: boolean;
  onToggle?: (next: boolean) => void;
  /** makes the header a drag handle (shows the grip on hover) */
  onGrab?: (e: React.PointerEvent) => void;
  className?: string;
}
export declare function DiffHunk(props: DiffHunkProps): JSX.Element;
