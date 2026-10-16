import * as React from "react";

export type DiffLine = string | { t: "add" | "rem" | "hunk" | "ctx"; s: string };
/** Diff block: toolbar (path · tools · Viewed) over hunks or plain unified lines. States: unified · split · viewed (folded, green edge; the folded row has hover and focus). */
export interface DiffViewProps {
  /** path shown in the toolbar */
  file?: string;
  /** right side of the toolbar, e.g. <Segmented size="sm" …/> for Unified / Side by side */
  tools?: React.ReactNode;
  /** plain unified lines (ignored when children are given) */
  lines?: DiffLine[];
  maxHeight?: number;
  /** marked as viewed: the body folds into one green line */
  viewed?: boolean;
  /** shows the Viewed toggle in the toolbar */
  onViewedChange?: (next: boolean) => void;
  className?: string;
  /** DiffHunk elements */
  children?: React.ReactNode;
}
export declare function DiffView(props: DiffViewProps): JSX.Element;
