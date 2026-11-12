import * as React from "react";

/** A line with its git sigil, one line per side; changed words in git's delimiters, "[-…-]" only on a removed line ("-a [-old-] b"), "{+…+}" only on an added one ("+a {+new+} b") — or the parsed form: on an added or removed line, `runs` are [text, changed] pairs. A string has no escape: code holding "[-", "-]", "{+" or "+}" goes in the parsed form. */
export type DiffLine =
  | string
  | { t: "add" | "rem"; s: string; runs?: Array<[string, boolean]> }
  | { t: "hunk" | "ctx"; s: string };
/** Diff block: toolbar (path · tools · Viewed) over hunks or plain unified lines. States: unified · split · viewed (folded, green edge; the folded row has hover and focus) · word marks (a changed run on --add-word-bg / --rem-word-bg, --text glyphs). */
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
