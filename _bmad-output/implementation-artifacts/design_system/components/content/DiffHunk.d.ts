import * as React from "react";
import type { DiffLine } from "./DiffView";

/** One hunk of a file's color-words diff, selectable for commit / split (whole or by part) and draggable onto another change. Unified, its numbers stay pinned at the visible left edge while the text scrolls. States: rest · selected (header --accent-soft-hi, 2px accent edge on every line) · some parts picked (header --accent at 12 %, the edge on their lines) · focus-visible (inside) · grab (grip on hover) · lifted (.38, dashed) · rows: context, removed, added, changed (both numbers in their hue, no fill) · side by side (each old and new line once, whole, with its number) · word marks (as DiffView, in both modes). */
export interface DiffHunkProps {
  /** header text; default built from the lines' numbers: "@@ −12,6 +12,9 @@" */
  range?: string;
  /** first numbers for git-sigil lines, which carry none of their own */
  oldStart?: number;
  newStart?: number;
  /** enclosing scope, e.g. "class SwipeController" */
  context?: string;
  /** color-words lines as in DiffView ("~13:13|  onEnd({+d+})", "+:14|  _commit();"), or git-sigil lines numbered from oldStart / newStart. Whitespace ignored (Story 10.41): exactly jj diff -w's lines, a whitespace-only line a context line with its marks (" 6:8|      {+  +}x,"); `{ t: "gap", n }` stands for n whitespace-only lines jj skips (open: they follow it; fixed: a pick keeps it open, no Show / Hide); `{ t: "fold", n }` is a whitespace-only part's run, closed one hatched row with its checkbox */
  lines: Array<DiffLine | WhitespaceGap>;
  /** as DiffView's `wordMarks` (default true); a DiffView with wordMarks={false} turns them off for its hunks too */
  wordMarks?: boolean;
  mode?: "unified" | "split";
  /** show the selection checkbox (mutable changes) */
  selectable?: boolean;
  selected?: boolean;
  /** being dragged onto another change */
  lifted?: boolean;
  onToggle?: (next: boolean) => void;
  /** makes the header a drag handle (shows the grip on hover) */
  onGrab?: (e: React.PointerEvent) => void;
  /** each line's part — jj's diff-editor section, 0-based; null for context. A selectable hunk with more than one part shows "N parts" and a checkbox per part */
  parts?: (number | null)[];
  /** the picked parts; some of them → the header on --accent at 12 % and the hunk checkbox mixed */
  picked?: number[];
  onTogglePart?: (part: number) => void;
  /** whitespace ignored (Story 10.41): a gap's Show (or a closed fold's row) was clicked — open it; `part` from `parts` */
  onShow?: (row: WhitespaceGap, part: number | null) => void;
  /** whitespace ignored: an open gap's Hide was clicked — close it */
  onHide?: (row: WhitespaceGap, part: number | null) => void;
  className?: string;
}
/** Hidden whitespace-only lines in one row at their place (Story 10.41): a gap, or a whitespace-only part's fold. */
export interface WhitespaceGap {
  t: "gap" | "fold";
  /** how many whitespace-only lines it stands for; identical lines between them (a blank line) open with them as plain context but do not count */
  n: number;
  /** its lines follow it; it reads "N lines with only whitespace changes" with Hide */
  open?: boolean;
  /** a pick keeps it open: no Show / Hide */
  fixed?: boolean;
}
export declare function DiffHunk(props: DiffHunkProps): JSX.Element;
