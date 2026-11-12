import * as React from "react";
import type { DiffLine } from "./DiffView";

/** One hunk of a file's color-words diff, selectable for commit / split and draggable onto another change. States: rest · selected (header --accent-soft-hi, 2px accent edge on every line) · focus-visible (inside) · grab (grip on hover) · lifted (.38, dashed) · rows: context, removed, added, changed (both numbers in their hue, no fill) · side by side (each old and new line once, whole, with its number) · word marks (as DiffView, in both modes). */
export interface DiffHunkProps {
  /** header text; default built from the lines' numbers: "@@ −12,6 +12,9 @@" */
  range?: string;
  /** first numbers for git-sigil lines, which carry none of their own */
  oldStart?: number;
  newStart?: number;
  /** enclosing scope, e.g. "class SwipeController" */
  context?: string;
  /** color-words lines as in DiffView ("~13:13|  onEnd({+d+})", "+:14|  _commit();"), or git-sigil lines numbered from oldStart / newStart */
  lines: DiffLine[];
  /** the word-mark style the lines were loaded in, as DiffView's `marks` */
  marks?: "jj" | "words";
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
