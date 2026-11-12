import * as React from "react";

/** One color-words line (jj diff's default format): "<kind><left>:<right>|<text>" — kind " " context, "-" removed (left only), "+" added (right only), "~" changed (an inlined line holding both sides' words), e.g. " 12:12|  final x;", "~13:13|  onEnd({+d+})", "+:14|  _commit();", "-14:|  _reset();"; "#|<<<<<<< Created conflict" a conflict header. Changed words: "[-…-]" around a left-side run, "{+…+}" around a right-side one, on any line. Older git strings ("+…", "-…", " …") still parse, without numbers. Or the parsed form: `runs` are [text, side] pairs, side "rem" | "add" | null. A string has no escape: code holding "[-", "-]", "{+" or "+}" goes in the parsed form. */
export type DiffLine =
  | string
  | { t: "ctx" | "rem" | "add" | "chg"; l?: number; r?: number; s: string; runs?: Array<[string, "rem" | "add" | null]> }
  | { t: "hunk" | "hdr"; s: string };
/** Diff block: toolbar (path · tools · Viewed) over hunks or plain color-words lines (left and right number columns, then the text). States: unified · split · viewed (folded, green edge; the folded row has hover and focus) · removed / added / changed / context rows · word marks (a run on --rem-word-bg / --add-word-bg by its side, --text glyphs). */
export interface DiffViewProps {
  /** path shown in the toolbar */
  file?: string;
  /** right side of the toolbar, e.g. <Segmented size="sm" …/> for Unified / Side by side */
  tools?: React.ReactNode;
  /** plain color-words lines (ignored when children are given) */
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
