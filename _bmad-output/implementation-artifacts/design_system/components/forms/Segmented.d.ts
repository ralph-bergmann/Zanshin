import * as React from "react";

export interface SegmentedOption { value: string; label?: React.ReactNode; icon?: string | React.ReactNode; title?: string; }
/** 2–4 mutually exclusive options on a quiet track. */
export interface SegmentedProps {
  options: Array<string | SegmentedOption>;
  value?: string;
  onChange?: (value: string) => void;
  /** accessible group label */
  label?: string;
  /** default (view menu) · tabs (settings scope tabs) · inset (inside a settings row) */
  variant?: "default" | "tabs" | "inset";
  /** sm = 18px icon toggles (diff layout) */
  size?: "md" | "sm";
  role?: string;
}
export declare function Segmented(props: SegmentedProps): JSX.Element;
