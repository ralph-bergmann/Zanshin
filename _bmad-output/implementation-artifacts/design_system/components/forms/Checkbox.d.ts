import * as React from "react";

/** 15px selection box for files and hunks. Moon fill when on; a dash when only part is selected. */
export interface CheckboxProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onChange"> {
  checked?: boolean;
  /** part of the group is selected (shows a dash) */
  mixed?: boolean;
  /** receives the next value; a mixed box always turns on */
  onChange?: (next: boolean) => void;
  /** accessible label + tooltip, e.g. "Select hunk" */
  label?: string;
  disabled?: boolean;
}
export declare function Checkbox(props: CheckboxProps): JSX.Element;
