import * as React from "react";

export interface DayAxisDay {
  key?: string | number;
  /** "Today" · "Yesterday" · "Sep 23" (· year when it isn't this year) */
  label: string;
  /** label centre — on the divider below that day's first commit (the oldest day: below its first commit) */
  y: number;
  /** divider y; omitted for the oldest day */
  guide?: number | null;
}

/** The Free layout's day axis: dashed dividers between calendar days, one sticky label per day at the left edge. */
export interface DayAxisProps {
  days: DayAxisDay[];
  /** plane size */
  width: number;
  height: number;
  /** where the dividers start, default 0 */
  x0?: number;
  /** sticky offset of the label column — floating client: right of the rail or pinned panel (inset − 6) */
  stickyLeft?: number;
  /** label inset inside the column: 14 (default), 2 in the floating client */
  labelLeft?: number;
  className?: string;
  style?: React.CSSProperties;
}
export declare function DayAxis(props: DayAxisProps): JSX.Element;

/** The day pill alone: mono 11px, --text-muted on --card-solid, 1px --border, radius 5. */
export declare function DayLabel(props: { children?: React.ReactNode; className?: string; style?: React.CSSProperties }): JSX.Element;
