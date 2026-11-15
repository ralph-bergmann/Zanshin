import * as React from "react";
import type { DiffLine } from "./DiffView";

/** One hunk of a file's color-words diff, pickable for commit / split by part. No header (Story 10.43): hunks follow each other with a 1px line, or a gap row between them. Unified, its gutter and numbers stay pinned at the visible left edge while the text scrolls. States: rest · a part picked (2px --accent-line bar on its rows) · a part's checkbox hovered (the same bar on its rows) · lifted (.38, dashed) · rows: context, removed, added, changed (both numbers in their hue, no fill) · gap rows (unchanged lines; whitespace-only lines; a hatched whitespace-only part) · side by side (each old and new line once, whole, with its number) · word marks (as DiffView, in both modes). */
export interface DiffHunkProps {
  /** first numbers for git-sigil lines, which carry none of their own */
  oldStart?: number;
  newStart?: number;
  /** color-words lines as in DiffView ("~13:13|  onEnd({+d+})", "+:14|  _commit();"), or git-sigil lines numbered from oldStart / newStart, and gap rows at their place: `{ t: "unchanged", n }` for hidden unchanged lines (Story 10.43); whitespace ignored (Story 10.41), exactly jj diff -w's lines, a whitespace-only line a context line with its marks (" 6:8|      {+  +}x,"), `{ t: "gap", n }` for whitespace-only lines jj skips, `{ t: "fold", n }` for a whitespace-only part's run */
  lines: Array<DiffLine | UnchangedGap | WhitespaceGap>;
  /** as DiffView's `wordMarks` (default true); a DiffView with wordMarks={false} turns them off for its hunks too */
  wordMarks?: boolean;
  mode?: "unified" | "split";
  /** show a checkbox per part (mutable changes) */
  selectable?: boolean;
  /** being dragged onto another change (its file row is in hand) */
  lifted?: boolean;
  /** each line's part — jj's diff-editor section, 0-based; null for context and unchanged gaps. Without it the changed lines are one part, 0. A selectable hunk shows one checkbox per part, on the part's first row */
  parts?: (number | null)[];
  /** the picked parts: their rows carry the 2px bar */
  picked?: number[];
  onTogglePart?: (part: number) => void;
  /** whitespace ignored (Story 10.41): a gap's Show (or a closed fold's row) was clicked — open it; `part` from `parts` */
  onShow?: (row: WhitespaceGap, part: number | null) => void;
  /** whitespace ignored: an open gap's Hide was clicked — close it */
  onHide?: (row: WhitespaceGap, part: number | null) => void;
  /** an unchanged gap's control was clicked (Story 10.43): "down" opens its first 20 lines, "up" its last 20, "all" every line. Without it the gap shows only its count */
  onExpand?: (row: UnchangedGap, how: "down" | "up" | "all") => void;
  className?: string;
}
/** Hidden unchanged lines in one row at their place (Story 10.43): "N unchanged lines"; n ≤ 20 opens with one ↕, more with ↓ / ↑ 20 and "Show all". */
export interface UnchangedGap {
  t: "unchanged";
  /** how many unchanged lines it stands for */
  n: number;
  /** before the file's first shown row: no ↓ */
  top?: boolean;
  /** after the file's last shown row: no ↑ */
  bottom?: boolean;
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
