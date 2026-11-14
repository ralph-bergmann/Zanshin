import * as React from "react";

/** One changed file, name first: status, the name, its folder cut in its middle, +/− counts; or a folder row of the tree. States: rest · hover · pressed · on (its diff shows, or the current folder) · on + hover · on + pressed · focus-visible (inside) · viewed · lifted · with checkbox (on / mixed) · tree (indented) · folder open / closed. */
export interface FileRowProps extends React.HTMLAttributes<HTMLDivElement> {
  /** M modified, R renamed (moon) · A added, C copied (green) · D deleted (red) */
  status?: "M" | "R" | "A" | "C" | "D";
  /** the repo path; name and folder come from it unless given; the tooltip */
  path?: string;
  /** the file's (or folder's) name, shown whole while folder text is left */
  name?: string;
  /** the folder with its trailing "/", dimmed; flat list only */
  folder?: string;
  /** the row sits in the tree: no folder text, indented by depth */
  tree?: boolean;
  /** folders above the row in the tree */
  depth?: number;
  /** makes it a folder row of the tree: its chevron open or closed */
  open?: boolean;
  /** a folder row's file count (the pill) */
  count?: number;
  added?: number;
  removed?: number;
  /** the file whose diff is shown, or the current folder */
  selected?: boolean;
  /** marked as viewed — green check, name and folder dimmed */
  viewed?: boolean;
  /** its hunks are being dragged onto another change */
  lifted?: boolean;
  /** show a selection Checkbox (mutable changes only); a folder's picks all its files */
  selectable?: boolean;
  checked?: boolean;
  /** some of its hunks (a folder: some of its files) are selected */
  mixed?: boolean;
  onCheck?: (next: boolean) => void;
}
export declare function FileRow(props: FileRowProps): JSX.Element;
