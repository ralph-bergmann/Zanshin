import * as React from "react";

/** Radio button (15px). Prefer Segmented for 2–3 short options in a row; radios for longer labels with hints. States: rest · hover · pressed · focus-visible · on · on + hover · on + pressed · disabled. */
export interface RadioProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onChange"> {
  checked?: boolean;
  onChange?: (checked: boolean) => void;
  label?: React.ReactNode;
  /** a dim second line under the label */
  hint?: React.ReactNode;
  disabled?: boolean;
  buttonRef?: React.Ref<HTMLButtonElement>;
  children?: React.ReactNode;
}
export declare function Radio(props: RadioProps): JSX.Element;
export interface RadioGroupOption { value: string; label: React.ReactNode; hint?: React.ReactNode; disabled?: boolean; title?: string; }
export interface RadioGroupProps {
  options: Array<string | RadioGroupOption>;
  value: string;
  onChange?: (value: string) => void;
  label?: string;
  direction?: "column" | "row";
  disabled?: boolean;
  className?: string;
}
export declare function RadioGroup(props: RadioGroupProps): JSX.Element;
