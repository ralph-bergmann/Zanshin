import * as React from "react";

/** Checkbox — selection of files and hunks (accent), the Viewed review state (tone add, size sm). The check draws in; check ↔ mixed morphs. States: rest · hover · pressed · focus-visible · on · mixed · on + hover · on + pressed · disabled · tone add (Viewed). */
export interface CheckboxProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onChange"> {
  checked?: boolean;
  /** some but not all — clicking it selects all */
  mixed?: boolean;
  onChange?: (checked: boolean) => void;
  /** accessible name + tooltip */
  label?: string;
  disabled?: boolean;
  /** md 15px · sm 13px (inside the Viewed chip) */
  size?: "md" | "sm";
  /** accent = selection · add = Viewed (green) */
  tone?: "accent" | "add";
  /** render a span (no role) inside a button that owns the checkbox role */
  presentational?: boolean;
}
export declare function Checkbox(props: CheckboxProps): JSX.Element;
