import * as React from "react";

/** One changed file: status, left-truncating path, +/− counts. States: rest · hover · pressed · on (its diff shows) · on + hover · on + pressed · focus-visible (inside) · viewed · lifted · with checkbox (on / mixed). */
export interface FileRowProps extends React.HTMLAttributes<HTMLDivElement> {
  /** M modified (moon) · A added (green) · D deleted (red) */
  status?: "M" | "A" | "D";
  path: string;
  added?: number;
  removed?: number;
  /** the file whose diff is shown below */
  selected?: boolean;
  /** marked as viewed — green check, dimmed path */
  viewed?: boolean;
  /** its hunks are being dragged onto another change */
  lifted?: boolean;
  /** show a selection Checkbox (mutable changes only) */
  selectable?: boolean;
  checked?: boolean;
  /** some of its hunks are selected */
  mixed?: boolean;
  onCheck?: (next: boolean) => void;
}
export declare function FileRow(props: FileRowProps): JSX.Element;
