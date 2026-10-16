import * as React from "react";

export interface SegmentedOption {
  value: string;
  label?: React.ReactNode;
  icon?: string | React.ReactNode;
  /** tooltip; for a disabled segment, the reason ("Open a project first") */
  title?: string;
  /** stays visible and hoverable (aria-disabled), can't be chosen, arrow keys skip it */
  disabled?: boolean;
}
/** Segmented control — 2–4 exclusive options; a thumb slides to the choice. States: rest · hover (label only) · pressed · focus-visible (inside) · on (the thumb) · disabled segment (aria-disabled, reason on its wrapper). */
export interface SegmentedProps {
  options: Array<string | SegmentedOption>;
  value: string;
  onChange?: (value: string) => void;
  /** accessible name of the group */
  label?: string;
  /** outer heights on the control scale: default 26 · tabs 36 (scope tabs) · inset 30 (in a settings row, like the Select beside it) */
  variant?: "default" | "tabs" | "inset";
  /** sm: 22 — icon toggles */
  size?: "md" | "sm";
  role?: string;
  className?: string;
}
export declare function Segmented(props: SegmentedProps): JSX.Element;
