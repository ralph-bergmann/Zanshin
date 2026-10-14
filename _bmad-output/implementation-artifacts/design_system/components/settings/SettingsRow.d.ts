import * as React from "react";

/** One setting: label, optional hint and config key on the left, the control on the right (min 46px). */
export interface SettingsRowProps {
  label: React.ReactNode;
  /** one plain sentence on what changes */
  hint?: React.ReactNode;
  /** the jj config key this row writes, e.g. "user.email" or 'revset-aliases."trunk()"' (mono, faint) */
  configKey?: string;
  /** control goes full width under the label (long values) */
  stack?: boolean;
  className?: string;
  children?: React.ReactNode;
}
export declare function SettingsRow(props: SettingsRowProps): JSX.Element;
