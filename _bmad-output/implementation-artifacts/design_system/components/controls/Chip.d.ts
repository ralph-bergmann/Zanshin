import * as React from "react";

/** Chip: toggle ("Aa") · not ("~") · filter (value + ✕) · add (dashed "+ …"). 26px (sm 22px). States: rest · hover · pressed · focus-visible · on (toggle: soft → soft-hi → ring · not: rem-bg → rem-bg-hover → rem-bg-press; the label turns --text) · disabled · add: dashed → solid. */
export interface ChipProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onChange"> {
  kind?: "toggle" | "not" | "filter" | "add";
  on?: boolean;
  onChange?: (on: boolean) => void;
  /** filter: the ✕ */
  onRemove?: () => void;
  label?: React.ReactNode;
  mono?: boolean;
  icon?: string;
  size?: "md" | "sm";
  children?: React.ReactNode;
}
export declare function Chip(props: ChipProps): JSX.Element;
