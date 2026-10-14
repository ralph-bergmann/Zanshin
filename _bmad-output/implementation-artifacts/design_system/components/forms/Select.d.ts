import * as React from "react";

/** Native select in the inset-field skin (30px, min 170px). */
export interface SelectProps extends Omit<React.SelectHTMLAttributes<HTMLSelectElement>, "onChange"> {
  options: Array<string | { value: string; label: string }>;
  value?: string;
  onChange?: (value: string) => void;
  label?: string;
}
export declare function Select(props: SelectProps): JSX.Element;
