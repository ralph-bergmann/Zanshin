import * as React from "react";

/** One changed file, name first: the name, its quiet word (new · deleted · from …), its folder cut in its middle; or a folder row of the tree (its glyph open or closed). No status letter, no +/− counts (Story 10.42). States: rest · hover · pressed · on (its diff shows, or the current folder) · on + hover · on + pressed · focus-visible (inside) · viewed · masked · lifted · with checkbox (on / mixed; unchecked shows on demand in a .zs-check-reveal pane) · tree (indented) · folder open / closed. */
export interface FileRowProps extends React.HTMLAttributes<HTMLDivElement> {
  /** jj's kind: A added → "new" in --add · D deleted → "deleted" in --rem · R renamed, C copied → "from …" (with from) · M modified → no word */
  status?: "M" | "R" | "A" | "C" | "D";
  /** the repo path; name and folder come from it unless given; the tooltip */
  path?: string;
  /** a rename's or copy's old path: the word names its file name while the folder is the same, else the whole old path; the tooltip reads `old → new` */
  from?: string;
  /** the file's (or folder's) name, shown whole while folder text is left */
  name?: string;
  /** the folder with its trailing "/", dimmed; flat list only */
  folder?: string;
  /** the row sits in the tree: no folder text, indented by depth */
  tree?: boolean;
  /** folders above the row in the tree */
  depth?: number;
  /** makes it a folder row of the tree: its folder glyph open or closed */
  open?: boolean;
  /** the file whose diff is shown, or the current folder */
  selected?: boolean;
  /** marked as viewed — green check, name and folder dimmed */
  viewed?: boolean;
  /** a ticked file mask hides it and it shows anyway (Show): the row at .55, eye-off 12 in --text-faint after the name, the tooltip "<path> · hidden by a file mask" */
  masked?: boolean;
  /** its hunks are being dragged onto another change */
  lifted?: boolean;
  /** reserve the 22px check column with a selection Checkbox (mutable changes only); a folder's picks all its files */
  selectable?: boolean;
  checked?: boolean;
  /** some of its hunks (a folder: some of its files) are selected */
  mixed?: boolean;
  onCheck?: (next: boolean) => void;
}
export declare function FileRow(props: FileRowProps): JSX.Element;
