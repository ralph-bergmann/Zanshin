import * as React from "react";

/** One setting: label, optional hint and config key on the left, the control on the right (min 46px). States: none of its own — its control's; stack · navigation row (onOpen): rest · hover (--fl-on) · pressed (--fl-press) · focus-visible (inside). */
export interface SettingsRowProps {
  label: React.ReactNode;
  /** one plain sentence on what changes (a navigation row: the current setting in words) */
  hint?: React.ReactNode;
  /** the jj config key this row writes, e.g. "user.email" or 'revset-aliases."trunk()"' (mono, faint) */
  configKey?: string;
  /** control goes full width under the label (long values) */
  stack?: boolean;
  /** makes the row a button that opens a page inside the tab (SettingsPage) — children become its value, followed by › */
  onOpen?: () => void;
  className?: string;
  children?: React.ReactNode;
}
export declare function SettingsRow(props: SettingsRowProps): JSX.Element;
