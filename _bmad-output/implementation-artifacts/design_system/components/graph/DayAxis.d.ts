import * as React from "react";

export interface DayAxisDay {
  key?: string | number;
  /** "Today" · "Yesterday" · "Sep 23" — never a year; years are labels of their own (`years`) */
  label: string;
  /** label centre — on the divider below that day's first commit (the oldest day: below its first commit) */
  y: number;
  /** divider y; omitted for the oldest day */
  guide?: number | null;
}

/** The Free layout's day axis: dashed dividers between calendar days, one sticky label per day at the left edge. States: none — labels stick to the left edge. */
/** A year boundary (sync #22): the year that begins there reading upward, labelled just above that day's label. */
export interface DayAxisYear {
  key?: string | number;
  year: number;
  /** the day label's y at that divider */
  y: number;
}

export interface DayAxisProps {
  days: DayAxisDay[];
  /** year labels — only where a year begins; none for a one-year history, none inside a GraphBreak */
  years?: DayAxisYear[];
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
