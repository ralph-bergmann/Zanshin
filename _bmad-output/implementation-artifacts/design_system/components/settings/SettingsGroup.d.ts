import * as React from "react";

/**
 * Caps heading + one rounded box of SettingsRows.
 */
export interface SettingsGroupProps {
  /** caps heading, e.g. "Appearance", "Remotes" */
  title?: string;
  className?: string;
  children?: React.ReactNode;
}
export declare function SettingsGroup(props: SettingsGroupProps): JSX.Element;
