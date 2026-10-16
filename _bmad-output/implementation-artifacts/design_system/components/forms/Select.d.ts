import * as React from "react";

export interface SelectOption { value: string; label?: React.ReactNode; /** what typeahead matches (default: a string label, else the value) */ text?: string; disabled?: boolean; mono?: boolean; }
/** Pop-up button: the field's well, value, double chevron. The list (a Menu) opens over the trigger, the chosen row on top of it. States: rest · hover · pressed · open · focus-visible · disabled; the list: a Menu (chosen row checked). */
export interface SelectProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onChange"> {
  /** strings, option objects, "sep", { header } — value "__custom" calls onCustom ("Custom…") */
  options: Array<string | SelectOption | "sep" | { header: string }>;
  value: string;
  onChange?: (value: string) => void;
  onCustom?: () => void;
  label?: string;
  /** set values in JetBrains Mono (bookmarks, remotes) */
  mono?: boolean;
  /** over (default — pick a value) · below (pull-down) */
  placement?: "over" | "below";
  disabled?: boolean;
}
export declare function Select(props: SelectProps): JSX.Element;
